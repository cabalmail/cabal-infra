import SwiftUI
import CabalmailKit

/// App entry point for the native macOS target.
///
/// Shares the same observable roots as the iOS/iPadOS/visionOS target
/// (`AppState`, `Preferences`) so every scene binds the same backing
/// state. macOS gets two scenes: the main mail window and a General-only
/// Settings window (⌘,). Address and folder management lives in the main
/// window's mailbox sidebar (`AddressListView` / `FolderListView`), which
/// carries the full request/revoke and create/delete affordances.
@main
struct CabalmailMacApp: App {
    @State private var appState = AppState()
    @State private var preferences = Preferences(store: UbiquitousPreferenceStore())

    var body: some Scene {
        WindowGroup("Cabalmail", id: "main") {
            ContentView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .task {
                    await appState.restoreIfPossible()
                    if preferences.crashReportingEnabled {
                        appState.client?.setCrashReportingEnabled(true)
                    }
                }
                .onChange(of: appState.client != nil) { _, hasClient in
                    guard hasClient else { return }
                    if preferences.crashReportingEnabled {
                        appState.client?.setCrashReportingEnabled(true)
                    }
                }
                .onOpenURL { url in
                    // mailto: clicks from Safari / Mail.app / other
                    // apps route here once the user has set Cabalmail
                    // as macOS's default mail handler (System Settings
                    // -> Desktop & Dock -> Default mail reader).
                    if let mailto = MailtoURL(url) {
                        appState.requestCompose(seed: mailto.draft())
                    }
                }
        }
        .commands {
            CabalmailCommands(appState: appState)
        }
        // Standalone compose window scene — matches every other Mac
        // mail client. The Cabalmail iOS target installs the same
        // scene so the iPad path lights up automatically.
        ComposeWindowScene(appState: appState, preferences: preferences)
        Settings {
            SettingsTabsView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .frame(minWidth: 560, minHeight: 640)
        }
    }

    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
