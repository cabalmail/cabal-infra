import Foundation
import CabalmailKit

// The list's lifecycle entries -- its first load, pull-to-refresh and the
// Refresh command -- which route between the folder window and a search,
// and the filter pills' counts.
extension MessageListViewModel {
    /// First load for a freshly built model: the cached snapshot, then the
    /// folder refresh, then the folder's sticky pill.
    ///
    /// The pill applies from the first paint: `filterTab` is set before the
    /// cache hydrates so the cached rows are narrowed at once, and the
    /// pill's server search runs once the folder's STATUS has driven the
    /// pill counts -- the same two steps a tap performs (`selectFilter`).
    ///
    /// Unstructured, model-owned task, so a cancellation of the view's
    /// `.task` (SwiftUI fires it mid-push transition — same class as the
    /// detail view's #403) can't propagate into the first fetch. The view
    /// only runs this once per model, so a first load cut short there would
    /// end as `.cancelled`, silently, on an empty list with nothing left to
    /// retry it. Mirrors `refreshFromPull`.
    func loadInitial() async {
        guard envelopes.isEmpty else { return }
        let sticky = folder.map { preferences.mailFolderFilter(for: $0.path) } ?? .all
        filterTab = sticky
        await Task {
            await self.window?.hydrateFromCache()
            await self.window?.seedSavedCounts()
            await self.refresh()
            if sticky != .all { await self.applyFilter(sticky) }
        }.value
        window?.scheduleBottomPrefetch()
    }

    /// Pull-to-refresh entry point. Runs `refresh()` on an unstructured,
    /// model-owned `Task` and awaits it, so a cancellation of SwiftUI's
    /// `.refreshable` task doesn't propagate into the in-flight request and
    /// cut the refresh short as `.cancelled`. The embedded per-row swipe `List`s
    /// inherit the outer `.refreshable`, and that scroll interaction was
    /// cancelling the pull task mid-fetch; an unstructured task is detached
    /// from that cancellation. Mirrors the pagination cancel-storm fix.
    func refreshFromPull() async {
        await Task { await self.refresh() }.value
    }

    /// The All pill's folder count: the saved one until a STATUS answers.
    var allCount: Int { window.map { $0.savedMessageCount ?? Int($0.totalMessages) } ?? 0 }

    /// The Unread pill's count: the mail store's unread count for this
    /// folder, which the sidebar shows too, so the two are one number. None
    /// on the search surface, whose rows come from many folders. Setting it
    /// shows a count without vouching for it (`MailCounts.show`); nothing in
    /// the app does, since the mutation service moves the store's counts.
    var unseen: Int {
        get { folder.map { mailStore.counts.folderUnreadCounts[$0.path] ?? 0 } ?? 0 }
        set {
            guard let folder else { return }
            mailStore.counts.show(unread: newValue, folderPath: folder.path)
        }
    }

    /// The Flagged pill's count: the mail store's flagged count for this
    /// folder. As `unseen`.
    var flagged: Int {
        get { folder.map { mailStore.counts.folderFlaggedCounts[$0.path] ?? 0 } ?? 0 }
        set {
            guard let folder else { return }
            mailStore.counts.show(flagged: newValue, folderPath: folder.path)
        }
    }

    /// User-initiated "force reload." Asks the server first, then wipes the
    /// rows and the folder's on-disk envelope snapshot and rebuilds from the
    /// top (`FolderWindowLoader.resetForHardReload()`), then refreshes with
    /// the STATUS it asked for. Both the macOS `Mailbox > Refresh` menu item
    /// and the message-list toolbar's arrow.clockwise button route through
    /// this path, so the user has a way to escape stale state (e.g. rows
    /// that leaked into the snapshot, which a refresh prunes only where it
    /// can prove them gone). The change watcher and the 60-second fallback
    /// keep calling `refresh()`: they fire often, and the merge is the cheap
    /// "fold new mail in" loop the cache is designed around. The body cache
    /// is left alone: it's keyed per UID and never blindly batch-written.
    ///
    /// On the search surface there is no folder to wipe: it re-runs the
    /// active search, or does nothing. The refresh is routed, so a pill
    /// search that started during the probe re-runs instead.
    func hardReload() async {
        guard let window else {
            if isSearchActive { await refreshSearch() }
            return
        }
        // The spinner holds from the probe through the refresh it hands to.
        window.holdLoading()
        defer { window.releaseLoading() }
        guard let probe = await window.resetForHardReload() else { return }
        // The reset wiped the rows on screen, a pill's results among them, so
        // the re-run below walks one page, as a fresh pill does.
        if search.showsResults { search.rows.removeAll() }
        await refresh(prefetched: probe, startingOver: true)
    }
}
