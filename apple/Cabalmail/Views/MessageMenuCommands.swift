import SwiftUI

/// The Message menu, shared by both app targets.
///
/// macOS embeds it in `CabalmailCommands` (the menu-bar surface);
/// `CabalmailApp` installs it directly on the main `WindowGroup` so
/// iPadOS gets the same chords through the hardware-keyboard menu.
/// Every item dispatches through an `AppState` tick counter (see the
/// "Commands dispatch through AppState tick counters" note in
/// apple/README.md): the compose surfaces observe the reply ticks, and
/// the on-screen `MessageListView` observes the selection-scoped ticks,
/// applying the action to its current selection — so the chords work
/// regardless of which view holds first-responder focus.
///
/// Cmd+M deliberately shadows Window > Minimize: menu key equivalents
/// are matched in menu-bar order and custom CommandMenus precede the
/// Window menu, so Move to Folder wins. Filing messages is the far more
/// frequent action in a mail client.
///
/// The Delete-key archive/trash chord is NOT here: a bare-key menu
/// equivalent would steal Backspace from every text field. It lives as
/// a focus-scoped `.onKeyPress(.delete)` on the message list instead,
/// beside the Esc / Cmd-A handlers.
struct MessageMenuCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Message") {
            Button("Reply") { appState.requestReply() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Reply All") { appState.requestReplyAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { appState.requestForward() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Mark as Read/Unread") { appState.requestToggleSeen() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Flag/Unflag") { appState.requestToggleFlagged() }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Move to Folder…") { appState.requestMoveSelection() }
                .keyboardShortcut("m", modifiers: .command)
        }
    }
}
