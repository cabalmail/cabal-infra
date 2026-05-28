import Foundation

/// Per-folder count helpers split out of `AppState.swift` so that file
/// stays under the SwiftLint length cap. Storage stays on `AppState` —
/// only the mutator methods live here.
///
/// Subscribed folders' counts get refreshed proactively by
/// `FolderListViewModel`; unsubscribed folders are populated lazily on
/// selection, and the unsubscribed-folder banner's Refresh button writes
/// the freshest values through `setFolderCounts` so the sidebar badge and
/// the message-list view advance together.
@MainActor
extension AppState {
    /// Replace the unread count for one folder. Called after an
    /// authoritative `STATUS (UNSEEN)` when the caller doesn't have the
    /// total in hand (e.g. an optimistic delta-based recovery path).
    func setUnreadCount(folderPath: String, count: Int) {
        folderUnreadCounts[folderPath] = max(0, count)
    }

    /// Replace the unread + total counts for one folder in one shot.
    /// Preferred over `setUnreadCount` whenever a full STATUS reply is
    /// in hand, so the two maps don't drift.
    func setFolderCounts(folderPath: String, unread: Int, total: Int) {
        folderUnreadCounts[folderPath] = max(0, unread)
        folderTotalCounts[folderPath] = max(0, total)
    }

    /// Replace the whole unread map. Used by the folder list view model
    /// after a full STATUS walk so any folders that have disappeared
    /// drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
    }

    /// Bump (or reduce) the count for one folder. Clamped at zero so a
    /// stale +1 from a doubled signal can't make the badge negative.
    func applyUnreadDelta(folderPath: String, delta: Int) {
        let current = folderUnreadCounts[folderPath] ?? 0
        folderUnreadCounts[folderPath] = max(0, current + delta)
    }
}
