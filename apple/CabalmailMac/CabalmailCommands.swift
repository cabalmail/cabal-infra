import SwiftUI
import CabalmailKit

/// macOS menu-bar commands.
///
/// Phase 7 polish: add a native menu bar that matches every other Mac
/// mail client — File → New Message, Mailbox → Refresh, Message → Reply
/// / Reply All / Forward. Commands dispatch through `AppState`'s tick
/// counters so the focused view (or the always-on-screen list) reacts
/// via `onChange` without the menu bar needing a direct reference to a
/// view model.
///
/// Why Reply / Reply All / Forward live here rather than on the detail
/// view's toolbar Menu Buttons: a `.keyboardShortcut` attached to a
/// Button inside a Menu only fires while the detail scene holds AppKit
/// first-responder focus, and that focus is lost the moment a compose
/// window opens. Subsequent Cmd+R presses then no-op until the user
/// clicks back into the detail view. Hoisting the shortcuts up to the
/// menu bar keeps them globally active, with the detail view simply
/// observing the tick to run its existing `beginCompose(_:)` flow.
struct CabalmailCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                appState.requestCompose()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Message") {
            Button("Reply") { appState.requestReply() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Reply All") { appState.requestReplyAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { appState.requestForward() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
        CommandMenu("Mailbox") {
            // No keyboard shortcut: Cmd+R is the Reply chord above, and
            // the message-list toolbar's arrow.clockwise button +
            // pull-to-refresh on touch platforms cover the discovery
            // surface for refresh.
            Button("Refresh") {
                appState.requestRefresh()
            }
        }
    }
}
