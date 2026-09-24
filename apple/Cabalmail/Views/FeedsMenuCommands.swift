import SwiftUI

/// The Feeds menu (macOS menu bar; the iPadOS hardware-keyboard menu picks
/// it up from the same declaration). Commands dispatch through
/// `AppState.requestFeedCommand`, and the mounted feed sidebar answers the
/// catalog ones through `FeedManagementSheets` while the mounted item list
/// answers the item ones, the same tick pattern the Mailbox and Message
/// menus use. Dimmed while signed out: nothing is there to answer.
///
/// The item commands carry the Message menu's own chords (⌘T, ⌘⇧8) and the
/// Mailbox menu's ⌥⌘T, so a user who learned them on mail has them on feeds.
/// Two menus on one chord are only safe if exactly one is enabled at a time:
/// `SharedChordPolicy` gives the chord to the section in front.
struct FeedsMenuCommands: Commands {
    let appState: AppState

    var body: some Commands {
        let itemsLive = SharedChordPolicy.feedItemsLive(
            appState.feedMenuAvailability, activeSection: appState.activeSection
        )
        let markAllLive = SharedChordPolicy.feedMarkAllReadLive(
            appState.feedMenuAvailability, activeSection: appState.activeSection
        )
        CommandMenu("Feeds") {
            Button("Subscribe to Feed…") { appState.requestFeedCommand(.subscribe) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!available)
            Button("New Feed Folder…") { appState.requestFeedCommand(.newFolder) }
                .disabled(!available)
            Divider()
            Button("Import OPML…") { appState.requestFeedCommand(.importOpml) }
                .disabled(!available)
            Button("Export OPML…") { appState.requestFeedCommand(.exportOpml) }
                .disabled(!available)
            Divider()
            Button("Refresh Feeds") { appState.requestFeedCommand(.refresh) }
                .disabled(!available)
            Divider()
            // Acts on the selected list row, else the open item; the list
            // answers (`FeedItemListView.handleFeedCommand`) and no-ops with
            // neither, which is exactly when the item is dimmed.
            Button("Mark as Read/Unread") { appState.requestFeedCommand(.toggleRead) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!itemsLive)
            Button("Flag/Unflag") { appState.requestFeedCommand(.toggleFlag) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!itemsLive)
            // The current feed scope, through the list's own confirmation.
            Button("Mark All as Read") { appState.requestFeedCommand(.markAllRead) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!markAllLive)
            Divider()
            // The feed tree's Expand all / Collapse all, reachable from the
            // menu bar whichever pane has focus (the Mailbox menu carries the
            // mail tree's pair).
            Button("Expand All Folders") { appState.requestSidebarTree(.expandAllFeedFolders) }
                .disabled(!available)
            Button("Collapse All Folders") { appState.requestSidebarTree(.collapseAllFeedFolders) }
                .disabled(!available)
        }
    }

    private var available: Bool { appState.status == .signedIn }
}
