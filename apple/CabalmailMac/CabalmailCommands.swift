import SwiftUI
import CabalmailKit

/// macOS menu-bar commands.
///
/// Phase 7 polish: add a native menu bar that matches every other Mac
/// mail client — File → New Message, Mailbox → Refresh. Commands dispatch
/// through `AppState`'s tick counters so the message-list view reacts via
/// `onChange` without the menu bar needing a direct reference to the
/// currently-focused view model.
///
/// Not adding Message-level commands (Reply / Reply All / Forward) here
/// because those depend on the selected message — the detail view already
/// owns `.keyboardShortcut`-annotated buttons for them, which SwiftUI
/// routes to the selected scene automatically.
struct CabalmailCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                appState.requestCompose()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Mailbox") {
            // No keyboard shortcut. Cmd+R is the Reply chord in the
            // detail view's toolbar (Cmd+Shift+R reaches Reply All);
            // routing it to the message list as well left the binding
            // ambiguous and depended on focus to dispatch. The menu
            // item plus the message-list toolbar's arrow.clockwise
            // button covers the discovery surface without overloading
            // a chord the user expects to mean Reply.
            Button("Refresh") {
                appState.requestRefresh()
            }
        }
    }
}
