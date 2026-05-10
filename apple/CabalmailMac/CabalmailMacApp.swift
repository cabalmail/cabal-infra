import SwiftUI
import CabalmailKit

/// App entry point for the native macOS target.
///
/// Shares the same observable roots as the iOS/iPadOS/visionOS target
/// (`AppState`, `Preferences`) so every scene binds the same backing
/// state. macOS gets four scenes: the main mail window plus singleton
/// Addresses and Folders windows reachable from the Window menu (and
/// ⌘⌥1 / ⌘⌥2) — instead of crowding everything into one window via a
/// tab picker (#385). The Settings scene wired to ⌘, replaces the iOS
/// Settings tab.
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
        Window("Addresses", id: "addresses") {
            SecondaryWindowRoot {
                AddressesView()
            }
            .environment(appState)
            .environment(preferences)
            .preferredColorScheme(colorScheme(for: preferences.theme))
            .frame(minWidth: 480, minHeight: 360)
        }
        .keyboardShortcut("1", modifiers: [.command, .option])
        Window("Folders", id: "folders") {
            SecondaryWindowRoot {
                FoldersAdminView()
            }
            .environment(appState)
            .environment(preferences)
            .preferredColorScheme(colorScheme(for: preferences.theme))
            .frame(minWidth: 480, minHeight: 360)
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        Settings {
            SettingsView()
                .environment(appState)
                .environment(preferences)
                .frame(minWidth: 420, minHeight: 480)
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
