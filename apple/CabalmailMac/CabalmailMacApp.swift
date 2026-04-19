import SwiftUI
import CabalmailKit

/// App entry point for the native macOS target.
///
/// Shares the same observable roots as the iOS/iPadOS/visionOS target
/// (`AppState`, `Preferences`) so the `Settings` scene wired to ⌘, can
/// bind the same `Preferences` instance the main window uses. The iOS
/// target hides the Settings tab on macOS since this scene replaces it.
@main
struct CabalmailMacApp: App {
    @State private var appState = AppState()
    @State private var preferences = Preferences(store: UbiquitousPreferenceStore())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .task {
                    await appState.restoreIfPossible()
                }
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
                .environment(preferences)
                .frame(minWidth: 420, minHeight: 480)
        }
        #endif
    }

    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
