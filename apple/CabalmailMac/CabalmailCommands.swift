import SwiftUI
import CabalmailKit

/// macOS menu-bar commands.
///
/// Phase 7 polish: add a native menu bar that matches every other Mac
/// mail client — File → New Message, Mailbox → Refresh, Message → Reply
/// / Reply All / Forward / Mark / Flag / Move. Commands dispatch through
/// `AppState`'s tick counters so the focused view (or the always-on-
/// screen list) reacts via `onChange` without the menu bar needing a
/// direct reference to a view model.
///
/// Why the Message actions live in the menu bar rather than on the
/// detail view's toolbar Menu Buttons: a `.keyboardShortcut` attached to
/// a Button inside a Menu only fires while the detail scene holds AppKit
/// first-responder focus, and that focus is lost the moment a compose
/// window opens. Subsequent Cmd+R presses then no-op until the user
/// clicks back into the detail view. Hoisting the shortcuts up to the
/// menu bar keeps them globally active, with the detail view simply
/// observing the tick to run its existing `beginCompose(_:)` flow. The
/// Message menu itself lives in the shared `MessageMenuCommands` so the
/// iPadOS hardware-keyboard menu carries the same chords.
struct CabalmailCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
        MessageMenuCommands(appState: appState)
        CommandMenu("Mailbox") {
            // No keyboard shortcut. Cmd+R is the Reply chord in the
            // Message menu above (Cmd+Shift+R reaches Reply All);
            // routing it to the message list as well left the binding
            // ambiguous and depended on focus to dispatch. The menu
            // item plus the message-list toolbar's arrow.clockwise
            // button covers the discovery surface without overloading
            // a chord the user expects to mean Reply.
            //
            // Both surfaces hit `requestRefresh()` -> `hardReload()`,
            // not the cheap merge-refresh — the manual paths exist
            // precisely so the user can escape stale in-memory state.
            Button("Refresh") {
                appState.requestRefresh()
            }
            // Unlike New Message, this one has nowhere to go with no mail
            // window on screen: `refreshRequestTick`'s only consumer is the
            // on-screen `MessageListView`. Dim it rather than advertise a
            // dead command — the rule `MessageMenuAvailability` already
            // applies to the Message menu (#985, #1162).
            .disabled(!appState.mailboxMenuAvailability.canRefresh)
        }
    }
}
