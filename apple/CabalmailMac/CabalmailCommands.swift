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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                appState.requestCompose()
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
        }
    }
}
