import Foundation
import Observation
import CabalmailKit

/// Backs `FolderListView`. Owns the folder list + unread counts, re-fetches
/// on explicit refresh.
///
/// Folder ordering follows the plan's sidebar layout: Inbox pinned first,
/// then user folders, then system folders grouped (Sent/Drafts/Trash/Junk).
///
/// Subscription is the user's signal about *attention*: subscribed folders
/// get their counts refreshed proactively (INBOX first so the user lands
/// in the inbox ASAP, then the rest concurrently), while unsubscribed
/// folders are strictly on-demand — `refreshFolderCount(path:)` is the
/// only path that ever touches them, and only when the user selects one.
@Observable
@MainActor
final class FolderListViewModel {
    var folders: [Folder] = []
    var isLoading = false
    var errorMessage: String?
    /// Paths whose counts are currently being fetched on-demand (lazy
    /// unsubscribed selection or the in-pane refresh button). The view
    /// reads this to render a spinner on the unsubscribed-folder banner's
    /// Refresh button.
    var refreshingPaths: Set<String> = []

    private let client: CabalmailClient
    private let appState: AppState
    /// Cap concurrent STATUS walks during the subscribed back-fill. The
    /// Lambda is happy to be hit in parallel, but the shared IMAP
    /// connection underneath serializes anyway — keeping this small
    /// avoids stacking dozens of pending tasks on first launch without
    /// changing real throughput.
    private let subscribedRefreshConcurrency = 4

    init(client: CabalmailClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    /// Manual refresh path (toolbar / pull-to-refresh on the sidebar).
    /// Re-fetches the folder list, then re-fetches subscribed-folder
    /// counts only. Previously-cached unsubscribed counts (from a user
    /// selection earlier in the session) survive the refresh per the
    /// subscription contract: we only spend resources proactively on
    /// folders the user has explicitly subscribed to.
    func refresh() async {
        await loadFolderList()
        await refreshInboxCount()
        await refreshSubscribedCounts()
    }

    /// Fetch + publish the folder list without walking per-folder STATUS.
    /// Split out so the parent view can seed a default selection (Inbox)
    /// the moment the sidebar arrives — the unread-count walk fans out
    /// across every folder and can take a second or two on first load,
    /// during which there's no reason to leave the user staring at an
    /// empty pane.
    func loadFolderList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let all = try await client.imapClient.listFolders()
            folders = sortForSidebar(all)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Folders the user has subscribed to. Mirrors the sort of `folders`
    /// (which already pins Inbox first, then user folders, then system
    /// folders), filtered to the subscribed subset.
    var subscribedFolders: [Folder] {
        folders.filter { $0.isSubscribed }
    }

    /// Optimistically flip the subscription state, fire the IMAP/API call,
    /// and revert on failure. Mirrors the React rail's behavior so toggling
    /// from the Apple sidebar feels as responsive as the web client.
    func toggleSubscription(_ folder: Folder) async {
        let target = !folder.isSubscribed
        applySubscription(path: folder.path, to: target)
        do {
            try await client.imapClient.connectAndAuthenticate()
            if target {
                try await client.imapClient.subscribe(path: folder.path)
            } else {
                try await client.imapClient.unsubscribe(path: folder.path)
            }
            errorMessage = nil
        } catch let error as CabalmailError {
            applySubscription(path: folder.path, to: !target)
            errorMessage = String(describing: error)
        } catch {
            applySubscription(path: folder.path, to: !target)
            errorMessage = error.localizedDescription
        }
    }

    private func applySubscription(path: String, to subscribed: Bool) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let previous = folders[index]
        folders[index] = Folder(
            path: previous.path,
            attributes: previous.attributes,
            isSubscribed: subscribed
        )
    }

    /// Fetch the INBOX STATUS and publish it. Called as early as
    /// possible at launch so the inbox badge is correct by the time the
    /// user's eyes reach it. Safe to fire in parallel with
    /// `loadFolderList()` — they share the IMAP connection but the API-
    /// backed client serializes its own commands, so the two requests
    /// just queue.
    func refreshInboxCount() async {
        await fetchAndPublishCount(path: "INBOX")
    }

    /// Walk subscribed folders (minus INBOX, which `refreshInboxCount()`
    /// handles separately) and publish counts as they land. Runs with
    /// bounded concurrency via a task group so a mailbox with 20+
    /// subscribed folders fills in noticeably faster than the previous
    /// sequential walk.
    func refreshSubscribedCounts() async {
        let targets = subscribedFolders
            .map(\.path)
            .filter { $0.caseInsensitiveCompare("INBOX") != .orderedSame }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index = 0
            while index < targets.count || inFlight > 0 {
                while inFlight < subscribedRefreshConcurrency, index < targets.count {
                    let path = targets[index]
                    index += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        await self?.fetchAndPublishCount(path: path)
                    }
                }
                await group.next()
                inFlight -= 1
            }
        }
    }

    /// On-demand fetch for a single folder, intended for unsubscribed
    /// folders the user has selected (or asked to refresh via the
    /// in-pane banner). Tracks the path in `refreshingPaths` so the UI
    /// can show a spinner while the round trip is in flight.
    func refreshFolderCount(path: String) async {
        await fetchAndPublishCount(path: path)
    }

    @discardableResult
    private func fetchAndPublishCount(path: String) async -> FolderStatus? {
        refreshingPaths.insert(path)
        defer { refreshingPaths.remove(path) }
        guard let status = try? await client.imapClient.status(path: path) else {
            return nil
        }
        let unread = status.unseen ?? 0
        let total = status.messages ?? 0
        appState.setFolderCounts(folderPath: path, unread: unread, total: total)
        return status
    }

    /// Inbox first, then user folders arranged as a `/`-delimited tree
    /// (peers alphabetical, children directly under their parent), then
    /// system folders grouped at the bottom.
    private func sortForSidebar(_ input: [Folder]) -> [Folder] {
        let systemNames: Set<String> = ["Sent", "Drafts", "Trash", "Junk", "Archive"]
        let inbox = input.filter { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
        let system = input
            .filter { systemNames.contains($0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let userFolders = input.filter { folder in
            !inbox.contains(folder)
                && !system.contains(folder)
                && !folder.attributes.contains("\\Noselect")
        }
        return inbox + FolderTree.sortUserTree(userFolders) + system
    }

    /// Indentation depth - delegates to `FolderTree.depth(for:)`.
    func depth(for folder: Folder) -> Int {
        FolderTree.depth(for: folder)
    }

    /// True iff this folder has at least one descendant in the current list -
    /// drives the per-folder collapse chevron in "All folders".
    func hasChildren(_ folder: Folder) -> Bool {
        FolderTree.hasChildren(folder, in: folders)
    }
}
