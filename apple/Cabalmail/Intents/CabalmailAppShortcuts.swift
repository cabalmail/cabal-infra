#if os(iOS)
import AppIntents

/// The "Hey Siri" surface: every phrase must contain `.applicationName`
/// (an App Intents rule), and the folder phrases resolve their parameter
/// against `MailFolderQuery.suggestedEntities()` — re-donated via
/// `updateAppShortcutParameters()` on each session start so Siri learns
/// the account's folder names.
struct CabalmailAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateRandomAddressIntent(),
            phrases: [
                "Get a new random address from \(.applicationName)",
                "Get a random \(.applicationName) address",
                "Create a random address in \(.applicationName)",
            ],
            shortTitle: "Random Address",
            systemImageName: "envelope.badge"
        )
        AppShortcut(
            intent: CreateNamedAddressIntent(),
            phrases: [
                "Get a new address from \(.applicationName)",
                "Create a new \(.applicationName) address",
                "Create an address in \(.applicationName)",
            ],
            shortTitle: "New Address",
            systemImageName: "at"
        )
        AppShortcut(
            intent: InboxStatusIntent(),
            phrases: [
                "Check my \(.applicationName) inbox",
                "Check my inbox in \(.applicationName)",
                "How many unread messages do I have in \(.applicationName)",
            ],
            shortTitle: "Check Inbox",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: OpenFolderIntent(),
            phrases: [
                "Open \(\.$folder) in \(.applicationName)",
                "Show my \(\.$folder) folder in \(.applicationName)",
                "Open a folder in \(.applicationName)",
            ],
            shortTitle: "Open Folder",
            systemImageName: "folder"
        )
    }
}
#endif
