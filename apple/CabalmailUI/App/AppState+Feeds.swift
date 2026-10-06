import Foundation
import CabalmailKit

/// What the Feeds menu can ask the feed surfaces to do. The catalog commands
/// are the feed sidebar's to answer (`FeedManagementSheets`); the item
/// commands — the mail Message menu's chords, applied to a feed item — are
/// the mounted `FeedItemListView`'s (`handleFeedCommand`).
enum FeedCommand: Equatable {
    case subscribe, newFolder, importOpml, exportOpml, refresh
    /// ⌘T on the selected (open) item.
    case toggleRead
    /// ⌘⇧8 on the selected (open) item.
    case toggleFlag
    /// ⌥⌘T on the list's scope, through its confirmation.
    case markAllRead
}

// The Feeds menu's command bumpers, and the foreground refresh the
// scene-phase handlers call. The periodic refresh it shares a pass with is
// `SessionPollers`'s, started and stopped with the session.
extension AppState {
    /// Names the command and bumps the tick the feed sidebar observes.
    func requestFeedCommand(_ command: FeedCommand, in window: UUID? = nil) {
        pendingFeedCommand = command
        commandWindow = window
        feedCommandTick += 1
    }

    /// Names the sidebar-tree command (Expand all / Collapse all on the mail
    /// or feed tree) and bumps the tick both sidebars observe; each applies
    /// the commands for the tree it owns.
    public func requestSidebarTree(_ command: SidebarTreeCommand, in window: UUID? = nil) {
        pendingSidebarTreeCommand = command
        commandWindow = window
        sidebarTreeCommandTick += 1
    }

    /// Foreground refresh for the feed reader: new items and the pending
    /// mutation queue. Called from the scene-phase handlers alongside the
    /// preferences reconcile; a no-op when signed out.
    public func refreshFeedsOnForeground() async {
        await sessionManager.pollers.refreshFeeds()
    }
}
