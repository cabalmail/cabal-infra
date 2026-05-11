import SwiftUI
import CabalmailKit

/// App entry point for the native macOS target.
///
/// Shares the same observable roots as the iOS/iPadOS/visionOS target
/// (`AppState`, `Preferences`) so every scene binds the same backing
/// state. macOS gets two scenes: the main mail window and a tabbed
/// Settings window (⌘,) with General / Addresses / Folders. Treating
/// addresses and folders as configuration matches the standard Mac
/// idiom and avoids the broken column distribution that crowding
/// everything into a single window produced (#385).
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
