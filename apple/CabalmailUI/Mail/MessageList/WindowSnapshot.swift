import Foundation
import CabalmailKit

/// What a `FolderWindowLoader` keeps of its folder for the next open: the
/// envelope snapshot (a warm-reopen cache, not a source of truth) and the
/// counts the last STATUS saved.
@MainActor
struct WindowSnapshot {
    let window: FolderWindowLoader

    /// Shows the folder's saved rows at once on open, sorted in the active
    /// order. Nothing says where they sit on the server now, so the window
    /// keeps no anchor; the refresh that follows decides (`WindowPlanner`)
    /// and sets the real count from STATUS.
    func hydrateFromCache() async {
        guard let snapshot = await window.client.envelopeCache.snapshot(for: window.folder.path) else { return }
        window.uidValidity = snapshot.uidValidity
        window.envelopes = window.placedInFolder(Array(snapshot.envelopes.values)).sorted(by: window.envelopeOrder)
        window.forgetWindowAnchor()
    }

    /// Starts the pills from the counts the last successful STATUS saved,
    /// possibly in an earlier launch, so a list opened offline doesn't read 0
    /// over its cached rows. The Unread and Flagged counts are seeded into the
    /// mail store where it has none of its own yet (`MailCounts.seed`), so
    /// the sidebar shows them too and every change moves both; the All count
    /// goes to `savedMessageCount` rather than `totalMessages`. The first
    /// STATUS that answers replaces all three (`applyStatusCounts`).
    func seedSavedCounts() async {
        guard let saved = await window.client.savedFolderStatus(path: window.folder.path) else { return }
        window.savedMessageCount = saved.messages.map { max(0, $0) }
        guard window.mailStore.acceptsCounts(from: window.client) else { return }
        let counts = window.mailStore.counts
        if counts.seed(folderPath: window.folder.path, from: saved) {
            counts.savedFolderCounts.markSeeded(window.folder.path)
        }
        // While the list showing this window has the folder open, a live
        // folder list arriving mustn't blank its seeded counts; once that
        // list has gone, they go as any other seeded badge.
        if let list = window.host {
            counts.savedFolderCounts.adopt(window.folder.path, by: list)
        }
    }

    /// Coalesces snapshot writes during paging: each page reschedules the
    /// write a second out, so a continuous scroll writes once when it
    /// settles rather than O(loaded count) on every page's critical path.
    /// `FolderWindowLoader.cancelTasks()` drops a pending write when the list
    /// goes away.
    func schedulePersist() {
        window.persistTask?.cancel()
        window.persistTask = Task { [weak window = self.window] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let window else { return }
            await window.snapshot.persistLoadedPages()
        }
    }

    /// Writes the loaded rows to the snapshot. Skipped once the front has
    /// been trimmed: the snapshot must stay top-anchored, so a relaunch
    /// hydrates the top of the folder, which keeps it to the first
    /// `windowCap` rows. A list that reopens further down (`ListPlaceTracker`)
    /// loads the page around its place. Search results are never the folder's
    /// snapshot, whatever was due to be written when the search started
    /// (#1870), and with the list gone nothing is written: whether a search
    /// was showing can't be known then.
    private func persistLoadedPages() async {
        guard !window.hasTrimmedFront, let list = window.host, !list.isSearchActive,
              let uidValidity = window.uidValidity, let uidNext = window.envelopes.map(\.uid).max() else { return }
        try? await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
    }

    private func persistCache(uidValidity: UInt32, uidNext: UInt32) async throws {
        try await window.client.envelopeCache.merge(
            envelopes: window.envelopes,
            uidValidity: uidValidity,
            uidNext: uidNext,
            into: window.folder.path
        )
    }
}
