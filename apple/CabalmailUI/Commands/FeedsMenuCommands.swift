import SwiftUI

/// The Feeds menu (macOS menu bar; the iPadOS hardware-keyboard menu picks
/// it up from the same declaration). Commands dispatch through
/// `AppState.requestFeedCommand`, and the mounted feed sidebar answers the
/// catalog ones through `FeedManagementSheets` while the mounted item list
/// answers the item ones. Dimmed with no signed-in main window in front.
///
/// The item commands carry the Message menu's own chords (⌘T, ⌘⇧8) and the
/// Mailbox menu's ⌥⌘T, so a user who learned them on mail has them on feeds.
/// Two menus on one chord are only safe if exactly one is enabled at a time:
/// `SharedChordPolicy` gives the chord to the section in front.
///
/// Each command is aimed at the focused main window, so a second window's
/// sidebar and list leave it alone.
public struct FeedsMenuCommands: Commands {
    let appState: AppState
    @FocusedValue(\.commandWindowID) private var focusedWindow
    /// The main window in front, whose surfaces say what the items act on.
    @FocusedValue(\.windowCommands) private var commands

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some Commands {
        let feeds = commands?.feedMenu ?? .none
        let section = commands?.activeSection ?? .mail
        let itemsLive = SharedChordPolicy.feedItemsLive(feeds, activeSection: section)
        let markAllLive = SharedChordPolicy.feedMarkAllReadLive(feeds, activeSection: section)
        CommandMenu("Feeds") {
            Button("Subscribe to Feed…") { appState.requestFeedCommand(.subscribe, in: target) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!available)
            Button("New Feed Folder…") { appState.requestFeedCommand(.newFolder, in: target) }
                .disabled(!available)
            Divider()
            Button("Import OPML…") { appState.requestFeedCommand(.importOpml, in: target) }
                .disabled(!available)
            Button("Export OPML…") { appState.requestFeedCommand(.exportOpml, in: target) }
                .disabled(!available)
            Divider()
            Button("Refresh Feeds") { appState.requestFeedCommand(.refresh, in: target) }
                .disabled(!available)
            Divider()
            // Acts on the selected list row, else the open item; the list
            // answers (`FeedItemListView.handleFeedCommand`) and no-ops with
            // neither, which is exactly when the item is dimmed.
            Button("Mark as Read/Unread") { appState.requestFeedCommand(.toggleRead, in: target) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!itemsLive)
            Button("Flag/Unflag") { appState.requestFeedCommand(.toggleFlag, in: target) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!itemsLive)
            // The current feed scope, through the list's own confirmation.
            Button("Mark All as Read") { appState.requestFeedCommand(.markAllRead, in: target) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!markAllLive)
            Divider()
            // The feed tree's Expand all / Collapse all, reachable from the
            // menu bar whichever pane has focus (the Mailbox menu carries the
            // mail tree's pair).
            Button("Expand All Folders") { appState.requestSidebarTree(.expandAllFeedFolders, in: target) }
                .disabled(!available)
            Button("Collapse All Folders") { appState.requestSidebarTree(.collapseAllFeedFolders, in: target) }
                .disabled(!available)
        }
    }

    private var available: Bool { commands != nil }
    private var target: UUID? { appState.menuCommandTarget(focused: focusedWindow) }
}
