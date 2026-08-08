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
struct MessageMenuCommands: Commands {
    let appState: AppState

    var body: some Commands {
        // Every command here is a no-op with nothing to act on, so each is
        // dimmed until it has a target — see `MessageMenuAvailability`, which
        // mirrors the two target rules the handlers themselves use.
        let availability = appState.messageMenuAvailability
        CommandMenu("Message") {
            Button("Reply") { appState.requestReply() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!availability.canReply)
            Button("Reply All") { appState.requestReplyAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Button("Forward") { appState.requestForward() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Divider()
            Button("Mark as Read/Unread") { appState.requestToggleSeen() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!availability.canActOnSelection)
            Button("Flag/Unflag") { appState.requestToggleFlagged() }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!availability.canActOnSelection)
            Button("Move to Folder…") { appState.requestMoveSelection() }
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!availability.canActOnSelection)
        }
    }
}
