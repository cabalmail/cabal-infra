import Foundation
import Observation
import CabalmailKit

/// Backs the Feeds sidebar section (wide layouts) and the Feeds tab's
/// sidebar (compact / visionOS): the catalog and unread counts from the
/// local `RssStore`, refreshed through `RssSyncEngine`.
///
/// Reads come from the store, so the sidebar renders offline and instantly;
/// `refresh()` pulls the catalog, syncs every subscription's items (four at a
/// time), pushes pending mutations, and reloads. Departed subscriptions'
/// per-feed web-view storage is dropped here, since only the app layer has
/// WebKit.
@Observable
@MainActor
final class FeedSidebarViewModel {
    var folders: [RssFolder] = []
    var subscriptions: [RssSubscription] = []
    var unreadCounts: [String: Int] = [:]
    var isRefreshing = false
    var errorMessage: String?
    /// True once the first `load()` has read the store, so an empty catalog
    /// can be told apart from a not-yet-loaded one.
    var hasLoaded = false

    private let client: CabalmailClient

    init(client: CabalmailClient, bus: FeedStateBus = .shared) {
        self.client = client
        // Any read / favorite change or refetch elsewhere moves the unread
        // badges; a refetch also refreshes each feed's health, so the whole
        // catalog is re-read from the store (cheap: one SQLite pass).
        bus.subscribe(self) { [weak self] change in
            Task { if change == nil { await self?.load() } else { await self?.reloadCounts() } }
        }
        // A subscribe, unsubscribe, or folder edit (the management sheets,
        // an OPML import) changes the tree itself.
        bus.subscribeCatalog(self) { [weak self] in
            Task { await self?.load() }
        }
    }

    var hasSubscriptions: Bool { !subscriptions.isEmpty }

    /// Reads the store (no network).
    func load() async {
        guard let store = client.rssStore else { return }
        do {
            folders = try await store.folders()
            subscriptions = try await store.subscriptions()
            unreadCounts = try await store.unreadCounts()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Catalog + items + pending drain, then a reload. Safe to call from
    /// several triggers at once: overlapping calls coalesce on `isRefreshing`.
    func refresh() async {
        guard !isRefreshing, let engine = client.rssSync else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        do {
            let diff = try await engine.refreshCatalog()
            await load()
            FeedWebStorage.drop(uuids: diff.removedDataStoreUuids)
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
        let failures = await engine.syncAll()
        if let first = failures.first, errorMessage == nil, failures.count == subscriptions.count,
           !subscriptions.isEmpty {
            // Every feed failed: almost certainly offline; one line, not one per feed.
            errorMessage = FeedErrorText.describe(first.value)
        }
        await load()
    }

    /// Reloads counts only (after a read-state change elsewhere).
    func reloadCounts() async {
        guard let store = client.rssStore else { return }
        unreadCounts = (try? await store.unreadCounts()) ?? unreadCounts
    }

    func subscription(id: String) -> RssSubscription? {
        subscriptions.first { $0.subscriptionId == id }
    }

    func folder(id: String) -> RssFolder? {
        folders.first { $0.folderId == id }
    }

    /// The display title for a scope (list header / navigation title).
    func title(for scope: RssItemScope) -> String {
        switch scope {
        case .all: return "All Feeds"
        case .folder(let id): return folder(id: id)?.name ?? "Folder"
        case .subscription(let id): return subscription(id: id)?.displayTitle ?? "Feed"
        }
    }

    func rows(collapsed: Set<String>, filter: String) -> [FeedSidebarRow] {
        FeedSidebarRows.rows(folders: folders, subscriptions: subscriptions, unreadCounts: unreadCounts,
                             collapsed: collapsed, filter: filter)
    }

}

/// User-facing wording for the RSS API's error codes (`docs/rss.md`) and
/// the transport failures around them.
enum FeedErrorText {
    /// The RSS API's error codes (`docs/rss.md`) in the user's words.
    private static let serverMessages: [String: String] = [
        "invalid_url": "That doesn't look like a feed address.",
        "not_https": "This feed isn't available over a secure connection, so Cabalmail can't fetch it.",
        "unreachable": "Cabalmail couldn't reach that address.",
        "not_a_feed": "That address didn't return a feed, and the page doesn't advertise one.",
        "needs_credentials": "The publisher requires a login for this feed. Private feeds arrive in a later release.",
        "feed_gone": "The publisher says that feed is gone.",
        "publisher_error": "The publisher returned an error. Try again later.",
        "unknown_folder": "That folder no longer exists.",
        "cyclic_folder": "A folder can't be moved inside itself.",
        "nothing_to_update": "Nothing to change.",
        "invalid_opml": "That file isn't an OPML outline.",
    ]

    static func describe(_ error: Error) -> String {
        if case let CabalmailError.server(code, message) = error {
            if let known = serverMessages[code] { return known }
            return message.isEmpty ? "Something went wrong (\(code))." : message
        }
        return error.localizedDescription
    }
}
