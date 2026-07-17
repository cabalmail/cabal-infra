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
    #if os(iOS)
    // Push notifications: APNs token callbacks and the notification-center
    // delegate have no SwiftUI-native surface, so the iOS build carries a
    // minimal UIKit delegate (see AppDelegate.swift). visionOS skips it —
    // the NSE and push registration are iOS-only for now (project.yml
    // destination-filters the extension the same way).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var appState = AppState()
    @State private var preferences = Preferences(store: UserDefaultsPreferenceStore())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .task {
                    // Hand the app-root Preferences to AppState before any
                    // restore so the session's PreferencesSyncCoordinator can
                    // pull the server copy (server wins on login).
                    appState.usePreferences(preferences)
                    // Launch-time auto-restore. `restoreIfPossible()` is a
                    // no-op once the user is signed in, so SwiftUI re-
                    // running this `.task` across scene re-attaches (e.g.
                    // on resume) stays cheap.
                    await appState.restoreIfPossible()
                    // Opt-in MetricKit needs to register as a subscriber
                    // *early* in the launch — before `applicationDidFinish
                    // Launching` returns — or diagnostic payloads from the
                    // last session won't be delivered. Re-running on every
                    // `.task` firing is safe because `start()` is idempotent.
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
                .onChange(of: scenePhase) { _, phase in
                    // Re-offer the session to the watch on every return to
                    // the foreground — see AppState.refreshWatchSession()
                    // for why the launch-time push alone strands a watch
                    // app installed while this app was already running.
                    guard phase == .active else { return }
                    Task { await appState.refreshWatchSession() }
                    // Pick up settings changed on another device while this
                    // one was backgrounded (server wins, unless a local edit
                    // is still pending its push).
                    Task { await appState.prefsCoordinator?.reconcile() }
                }
                .onOpenURL { url in
                    // Cold-launch mailto: arrives here before any view
                    // is wired to observe `composeRequestTick`. The seed
                    // is parked on `AppState.pendingComposeSeed` and
                    // drained by `ComposeRequestRouter`'s initial `.task`
                    // on the signed-in root.
                    if let mailto = MailtoURL(url) {
                        appState.requestCompose(seed: mailto.draft())
                    }
                }
        }
        // Same Message menu the macOS menu bar shows. On iPadOS the
        // commands surface through the hardware-keyboard menu (hold
        // Cmd) so Reply / Mark / Flag / Move get the same chords as
        // the Mac; iPhone carries them inertly.
        .commands {
            MessageMenuCommands(appState: appState)
            // Settings sheet shortcut. iOS has no Settings scene (macOS owns
            // Cmd+, through its `Settings {}` scene), so we claim the standard
            // app-settings slot and route it to the same tick the sidebar gear
            // bumps. Surfaces in the iPadOS hardware-keyboard menu.
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.requestSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // iPadOS and visionOS open compose as a real scene; iPhone
        // ignores the group because `composeOpensInWindow` keeps it on
        // the sheet path. Installing the WindowGroup on every iOS
        // build keeps the scene available the moment a user moves to a
        // multi-scene device (Stage Manager, iPad).
        ComposeWindowScene(appState: appState, preferences: preferences)
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
