import Foundation
import CabalmailKit

/// What the Feeds menu can ask the feed surfaces to do. The catalog commands
/// are the feed sidebar's to answer (`FeedManagementSheets`); the item
/// commands — the mail Message menu's chords, applied to a feed item — are
/// the mounted `FeedItemListView`'s (`handleFeedCommand`). Sent to the window
/// in front as `WindowCommand.feed(_:)`.
public enum FeedCommand: Hashable, CaseIterable, Sendable {
    case subscribe, newFolder, importOpml, exportOpml, refresh
    /// ⌘T on the selected (open) item.
    case toggleRead
    /// ⌘⇧8 on the selected (open) item.
    case toggleFlag
    /// ⌥⌘T on the list's scope, through its confirmation.
    case markAllRead
}

// The foreground refresh the scene-phase handlers call. The periodic refresh
// it shares a pass with is `SessionPollers`'s, started and stopped with the
// session.
extension AppState {
    /// Foreground refresh for the feed reader: new items and the pending
    /// mutation queue. Called from the scene-phase handlers alongside the
    /// preferences reconcile; a no-op when signed out.
    public func refreshFeedsOnForeground() async {
        await sessionManager.pollers.refreshFeeds()
    }
}
