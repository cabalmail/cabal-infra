import SwiftUI

/// The Message menu, shared by both app targets.
///
/// macOS embeds it in `CabalmailCommands` (the menu-bar surface);
/// `CabalmailApp` installs it directly on the main `WindowGroup` so
/// iPadOS gets the same chords through the hardware-keyboard menu.
/// Every item reads and acts on the commands of the main window in front
/// (`WindowCommands`, published with `focusedSceneValue`): its list answers
/// the selection-scoped items and its reader the reply family, so the chords
/// work whichever view holds first-responder focus, and another window's
/// list and reader leave them alone. With no main window in front (a compose
/// or Settings window, or none open) every item dims.
///
/// Cmd+M deliberately shadows Window > Minimize: menu key equivalents
/// are matched in menu-bar order and custom CommandMenus precede the
/// Window menu, so Move to Folder wins. Filing messages is the far more
/// frequent action in a mail client.
///
/// The Cmd+Delete dispose chord is NOT here: menu equivalents fire
/// app-wide, so it would trigger from the compose window and steal the
/// text system's delete-to-line-start chord mid-draft. It rides window-
/// scoped key equivalents instead (`DisposeChordButton`): the reader's for a
/// single open message, the list's for a multi-selection, so it acts on
/// the mail window only, but works there regardless of which pane has focus.
public struct MessageMenuCommands: Commands {
    @FocusedValue(\.windowCommands) private var commands

    public init() {}

    public var body: some Commands {
        // Every command here is a no-op with nothing to act on, so each is
        // dimmed until it has a target — see `MessageMenuAvailability`, which
        // mirrors the two target rules the handlers themselves use.
        let availability = commands?.messageMenu ?? .none
        // ⌘T and ⌘⇧8 are also the Feeds menu's chords; only the section in
        // front may hold them live (`SharedChordPolicy`).
        let itemsLive = SharedChordPolicy.mailItemsLive(availability, activeSection: commands?.activeSection ?? .mail)
        CommandMenu("Message") {
            Button("Reply") { commands?.send(.reply) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!availability.canReply)
            Button("Reply All") { commands?.send(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Button("Forward") { commands?.send(.forward) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!availability.canReply)
            Divider()
            Button("Mark as Read/Unread") { commands?.send(.toggleSeen) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!itemsLive)
            Button("Flag/Unflag") { commands?.send(.toggleFlagged) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!itemsLive)
            Button("Move to Folder…") { commands?.send(.moveSelection) }
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!availability.canActOnSelection)
        }
    }
}
