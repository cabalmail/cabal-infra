import SwiftUI

/// The Feeds menu (macOS menu bar; the iPadOS hardware-keyboard menu picks
/// it up from the same declaration). Commands go to the main window in front
/// (`WindowCommand.feed`): its feed sidebar answers the catalog ones through
/// `FeedManagementSheets`, and its item list the item ones. Dimmed with no
/// signed-in main window in front.
///
/// The item commands carry the Message menu's own chords (⌘T, ⌘⇧8) and the
/// Mailbox menu's ⌥⌘T, so a user who learned them on mail has them on feeds.
/// Two menus on one chord are only safe if exactly one is enabled at a time:
/// `SharedChordPolicy` gives the chord to the section in front.
public struct FeedsMenuCommands: Commands {
    /// The main window in front, whose surfaces say what the items act on.
    @FocusedValue(\.windowCommands) private var commands

    public init() {}

    public var body: some Commands {
        let feeds = commands?.feedMenu ?? .none
        let section = commands?.activeSection ?? .mail
        let itemsLive = SharedChordPolicy.feedItemsLive(feeds, activeSection: section)
        let markAllLive = SharedChordPolicy.feedMarkAllReadLive(feeds, activeSection: section)
        CommandMenu("Feeds") {
            Button("Subscribe to Feed…") { commands?.send(.feed(.subscribe)) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!available)
            Button("New Feed Folder…") { commands?.send(.feed(.newFolder)) }
                .disabled(!available)
            Divider()
            Button("Import OPML…") { commands?.send(.feed(.importOpml)) }
                .disabled(!available)
            Button("Export OPML…") { commands?.send(.feed(.exportOpml)) }
                .disabled(!available)
            Divider()
            Button("Refresh Feeds") { commands?.send(.feed(.refresh)) }
                .disabled(!available)
            Divider()
            // Acts on the selected list row, else the open item; the list
            // answers (`FeedItemListView.handleFeedCommand`) and no-ops with
            // neither, which is exactly when the item is dimmed.
            Button("Mark as Read/Unread") { commands?.send(.feed(.toggleRead)) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!itemsLive)
            Button("Flag/Unflag") { commands?.send(.feed(.toggleFlag)) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!itemsLive)
            // The current feed scope, through the list's own confirmation.
            Button("Mark All as Read") { commands?.send(.feed(.markAllRead)) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!markAllLive)
            Divider()
            // The feed tree's Expand all / Collapse all, reachable from the
            // menu bar whichever pane has focus (the Mailbox menu carries the
            // mail tree's pair).
            Button("Expand All Folders") { commands?.send(.sidebarTree(.expandAllFeedFolders)) }
                .disabled(!available)
            Button("Collapse All Folders") { commands?.send(.sidebarTree(.collapseAllFeedFolders)) }
                .disabled(!available)
        }
    }

    private var available: Bool { commands != nil }
}
