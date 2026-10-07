import Foundation
import Observation
import CabalmailKit

/// Backs the Feeds sidebar section (wide layouts) and the Feeds tab's
/// sidebar (compact / visionOS): the catalog and unread counts from the
/// local `RssStore`, refreshed through `RssSyncEngine`.
///
/// Reads come from the store, so the sidebar renders offline and instantly;
/// `refresh()` runs the engine's `syncAll` (the catalog, every
/// subscription's items four at a time, the pending mutations) and reloads. Departed subscriptions'
/// per-feed web-view storage is dropped here, since only the app layer has
/// WebKit.
@Observable
@MainActor
final class FeedSidebarViewModel {
    var folders: [RssFolder] = []
    var subscriptions: [RssSubscription] = []
    var unreadCounts: [String: Int] = [:]
    /// Cached items per subscription, for the badge's total under the
    /// `total` / `both` folder-count modes (`FolderCountBadge`).
    var totalCounts: [String: Int] = [:]
    var isRefreshing = false
    var errorMessage: String?
    /// True once the first `load()` has read the store, so an empty catalog
    /// can be told apart from a not-yet-loaded one.
    var hasLoaded = false
    /// True until a refresh runs to an outcome (synced, or failed for a
    /// reason worth showing), and again after one a cooperative cancel cut
    /// short. The views' `.task` refreshes while it holds, so the next
    /// appearance takes over a sync the last one abandoned (#1908; the
    /// `RulesViewModel.load` rule, #1328).
    private(set) var needsRefresh = true
    /// `refreshIfNeeded` calls waiting out the refresh in flight.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many of those there are; the tests' view of the wait.
    var waitingRefreshCount: Int { refreshWaiters.count }

    /// The client's `rssStore` / `rssSync`, or a test's. Nil on a bare
    /// client, where every load and refresh is a no-op.
    private let store: RssStore?
    private let engine: RssSyncEngine?

    convenience init(client: CabalmailClient, bus: FeedStateBus = .shared) {
        self.init(store: client.rssStore, engine: client.rssSync, bus: bus)
    }

    init(store: RssStore?, engine: RssSyncEngine?, bus: FeedStateBus = .shared) {
        self.store = store
        self.engine = engine
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
        guard let store else { return }
        do {
            folders = try await store.folders()
            subscriptions = try await store.subscriptions()
            unreadCounts = try await store.unreadCounts()
            totalCounts = try await store.totalCounts()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Catalog + items + pending drain, then a reload: the engine's one
    /// `syncAll` pass, which it joins to a pass the session's poller already
    /// has in flight. Safe to call from several triggers at once: overlapping
    /// calls coalesce on `isRefreshing`.
    func refresh() async {
        guard !isRefreshing, let engine else { return }
        isRefreshing = true
        defer { finishRefresh() }
        errorMessage = nil
        let report = await engine.syncAll()
        // A refresh whose task was cancelled (the views' `.task` as the
        // sidebar leaves the screen mid-sync: a push, a tab switch, the iPad
        // sidebar hidden) stops waiting and has nothing to report (#1908).
        // Read off the task, not the result.
        if let report, !Task.isCancelled {
            errorMessage = Self.errorLine(for: report)
        }
        // Cut short, the refresh is owed: the next `.task` runs it again.
        let cutShort = Task.isCancelled
        // Whatever reached the store before a cancel is shown regardless.
        await FeedWebStorage.dropDeparted(from: store)
        await load()
        needsRefresh = cutShort
    }

    /// The one line a pass leaves on the sidebar: the catalog's failure, or
    /// every feed failing (almost certainly offline; one line, not one per
    /// feed). A failed queue drain or some feeds failing says nothing here,
    /// and neither counts toward "every feed" (#1904).
    static func errorLine(for report: RssSyncReport) -> String? {
        if let error = report.catalogError { return FeedErrorText.describe(error) }
        if report.everyFeedFailed, let error = report.firstFeedError { return FeedErrorText.describe(error) }
        return nil
    }

    /// The views' `.task`: a refresh until one has run to an outcome. Waits
    /// out a refresh still in flight first, typically the one a cancelled
    /// `.task` started and is still unwinding as the view comes back, which
    /// `refresh()`'s coalescing would otherwise fold this call into, ending
    /// both with nothing loaded.
    func refreshIfNeeded() async {
        while isRefreshing {
            await withCheckedContinuation { refreshWaiters.append($0) }
            if Task.isCancelled { return }
        }
        guard needsRefresh, !Task.isCancelled else { return }
        await refresh()
    }

    /// Ends a refresh and wakes the `refreshIfNeeded` calls waiting on it.
    private func finishRefresh() {
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Reloads counts only (after a read-state change elsewhere). Totals
    /// are re-read too: a load-older or a sync lands in the same bus post.
    func reloadCounts() async {
        guard let store else { return }
        unreadCounts = (try? await store.unreadCounts()) ?? unreadCounts
        totalCounts = (try? await store.totalCounts()) ?? totalCounts
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

    func rows(
        collapsed: Set<String>,
        filter: String,
        unreadOnly: Bool = false,
        keep: RssItemScope? = nil
    ) -> [FeedSidebarRow] {
        FeedSidebarRows.rows(folders: folders, subscriptions: subscriptions, unreadCounts: unreadCounts,
                             totalCounts: totalCounts, collapsed: collapsed, filter: filter,
                             unreadOnly: unreadOnly, keep: keep)
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

    /// A failure without a token is `.http` and reads as its localized
    /// sentence, not the raw reply body.
    static func describe(_ error: Error) -> String {
        if case let CabalmailError.server(code, message) = error {
            if let known = serverMessages[code] { return known }
            return message.isEmpty ? "Something went wrong (\(code))." : message
        }
        return error.localizedDescription
    }
}
