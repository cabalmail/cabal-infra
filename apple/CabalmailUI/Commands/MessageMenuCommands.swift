import SwiftUI

/// The Message menu, shared by both app targets.
///
/// macOS embeds it in `CabalmailCommands` (the menu-bar surface);
/// `CabalmailApp` installs it directly on the main `WindowGroup` so
/// iPadOS gets the same chords through the hardware-keyboard menu.
/// Every item dispatches through an `AppState` tick counter (see the
/// "Commands dispatch through AppState tick counters" note in
/// docs/apple.md): the compose surfaces observe the reply ticks, and
/// the on-screen `MessageListView` observes the selection-scoped ticks,
/// applying the action to its current selection — so the chords work
/// regardless of which view holds first-responder focus.
///
/// Cmd+M deliberately shadows Window > Minimize: menu key equivalents
/// are matched in menu-bar order and custom CommandMenus precede the
/// Window menu, so Move to Folder wins. Filing messages is the far more
/// frequent action in a mail client.
///
/// The Cmd+Delete dispose chord is NOT here: menu equivalents fire
/// app-wide, so it would trigger from the compose window and steal the
/// text system's delete-to-line-start chord mid-draft. It rides window-
/// scoped key equivalents instead — the detail toolbar's dispose button
/// for a single open message, an invisible button on the message list
/// for a multi-selection — so it acts on the mail window only, but
/// works there regardless of which pane has focus.
///
/// Each command is aimed at the focused main window (`MainWindowCommandScope`),
/// or the one last in front while a compose window is key, so a second
/// window's list and reader leave it alone.
public struct MessageMenuCommands: Commands {
    let appState: AppState
    @FocusedValue(\.commandWindowID) private var focusedWindow

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some Commands {
        // Every command here is a no-op with nothing to act on, so each is
        // dimmed until it has a target — see `MessageMenuAvailability`, which
        // mirrors the two target rules the handlers themselves use.
        let availability = appState.messageMenuAvailability
        // ⌘T and ⌘⇧8 are also the Feeds menu's chords; only the section in
        // front may hold them live (`SharedChordPolicy`).
        let itemsLive = SharedChordPolicy.mailItemsLive(availability, activeSection: appState.activeSection)
        CommandMenu("Message") {
            Button("Reply") { appState.requestReply(in: target) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!availability.canReply)
            Button("Reply All") { appState.requestReplyAll(in: target) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Button("Forward") { appState.requestForward(in: target) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Divider()
            Button("Mark as Read/Unread") { appState.requestToggleSeen(in: target) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!itemsLive)
            Button("Flag/Unflag") { appState.requestToggleFlagged(in: target) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!itemsLive)
            Button("Move to Folder…") { appState.requestMoveSelection(in: target) }
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!availability.canActOnSelection)
        }
    }

    private var target: UUID? { appState.menuCommandTarget(focused: focusedWindow) }
}
