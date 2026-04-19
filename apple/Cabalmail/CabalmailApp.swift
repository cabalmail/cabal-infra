import SwiftUI
import CabalmailKit

/// App entry point for the iOS / iPadOS / visionOS target.
///
/// Hoists the `AppState` and `Preferences` observable roots so the macOS
/// target can mirror the same pattern (`Settings` scene needs to share the
/// same instances), and so both appear in the SwiftUI `@Environment` tree
/// for every downstream view.
@main
struct CabalmailApp: App {
    @State private var appState = AppState()
    @State private var preferences = Preferences(store: UbiquitousPreferenceStore())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .task {
                    // Launch-time auto-restore. `restoreIfPossible()` is a
                    // no-op once the user is signed in, so SwiftUI re-
                    // running this `.task` across scene re-attaches (e.g.
                    // on resume) stays cheap.
                    await appState.restoreIfPossible()
                }
        }
    }

    /// Maps the theme preference onto SwiftUI's optional `ColorScheme`.
    /// `nil` means "follow the system appearance" — i.e. the `.system`
    /// preference lets the OS switch light/dark with its own controls.
    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
