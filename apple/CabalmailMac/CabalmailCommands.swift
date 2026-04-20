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
            Button("Refresh") {
                appState.requestRefresh()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
