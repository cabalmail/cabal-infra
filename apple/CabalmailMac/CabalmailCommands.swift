import SwiftUI
import CabalmailKit
import CabalmailUI

/// macOS menu-bar commands.
///
/// Phase 7 polish: add a native menu bar that matches every other Mac
/// mail client — File → New Message, Mailbox → Refresh, Message → Reply
/// / Reply All / Forward / Mark / Flag / Move. Commands go to the main
/// window in front (`WindowCommands`), so its views react without the menu
/// bar needing a direct reference to a view model.
///
/// Why the Message actions live in the menu bar rather than on the
/// detail view's toolbar Menu Buttons: a `.keyboardShortcut` attached to
/// a Button inside a Menu only fires while the detail scene holds AppKit
/// first-responder focus, and that focus is lost the moment a compose
/// window opens. Subsequent Cmd+R presses then no-op until the user
/// clicks back into the detail view. Hoisting the shortcuts up to the
/// menu bar keeps them active in any main window, with the detail view
/// simply answering the command with its `beginCompose(_:)` flow. The
/// Message menu itself lives in the shared `MessageMenuCommands` so the
/// iPadOS hardware-keyboard menu carries the same chords.
struct CabalmailCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow
    /// The main window in front, which the Mailbox items act in; nil (they
    /// dim) with a compose or Settings window in front, or none open.
    @FocusedValue(\.windowCommands) private var commands

    var body: some Commands {
        // The deep-link router opens a main window through the `openWindow`
        // these commands hold, the one that works with every main window
        // closed (New Message below relies on it, #1162). Set on every
        // evaluation: each closure does the same, and the last one wins. A
        // bare `_ =` would be taken by the builder as one of the commands.
        // swiftlint:disable:next redundant_discardable_let
        let _ = MainMailWindow.opensForDeepLinks(using: openWindow)
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                // Opens the compose scene itself rather than bumping
                // `requestCompose()`: that tick's only consumer is
                // `ComposeRequestRouter`, installed on `SignedInRootView`
                // inside the main window, so with every window closed the
                // item stayed enabled and silently did nothing (#1162).
                // `MenuBarExtraMenu`'s identically-named item already took
                // this route, which is why it kept working there; both now
                // share `ComposeWindowCommand` so they cannot drift.
                ComposeWindowCommand.openNewMessage(
                    appState: appState,
                    openWindow: openWindow
                )
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        MessageMenuCommands()
        FeedsMenuCommands()
        CommandMenu("Mailbox") {
            // No keyboard shortcut. Cmd+R is the Reply chord in the
            // Message menu above (Cmd+Shift+R reaches Reply All);
            // routing it to the message list as well left the binding
            // ambiguous and depended on focus to dispatch. The menu
            // item plus the message-list toolbar's arrow.clockwise
            // button covers the discovery surface without overloading
            // a chord the user expects to mean Reply.
            //
            // Both surfaces send `.refresh` -> `hardReload()`, not the
            // cheap merge-refresh — the manual paths exist precisely so
            // the user can escape stale in-memory state.
            Button("Refresh") {
                commands?.send(.refresh)
            }
            // Unlike New Message, this one has nowhere to go with no mail
            // list in the window in front. Dim it rather than advertise a
            // dead command — the rule `MessageMenuAvailability` already
            // applies to the Message menu (#985, #1162).
            .disabled(!(commands?.mailbox.canRefresh ?? false))
            // ⌥⌘T: the Option variant of the Message menu's per-message ⌘T,
            // acting on the whole folder the list is showing. The Feeds menu
            // carries the same chord for a feed scope; `SharedChordPolicy`
            // enables whichever section is in front, never both. Confirmed
            // by the list before anything happens (`+MarkAllRead`).
            Button("Mark All as Read") {
                commands?.send(.markFolderRead)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!(commands.map {
                SharedChordPolicy.mailMarkAllReadLive($0.mailbox, activeSection: $0.activeSection)
            } ?? false))
            Divider()
            // The sidebar's Expand all / Collapse all buttons, as menu items
            // so they work whichever pane has focus. No chords: nothing
            // conventional is free (Cmd+Option+arrows are the outline
            // view's own), and the buttons are one click away.
            Button("Expand All Folders") { commands?.send(.sidebarTree(.expandAllFolders)) }
                .disabled(commands == nil)
            Button("Collapse All Folders") { commands?.send(.sidebarTree(.collapseAllFolders)) }
                .disabled(commands == nil)
        }
    }
}
