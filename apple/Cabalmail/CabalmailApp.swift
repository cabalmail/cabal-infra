import SwiftUI
import CabalmailKit
import CabalmailUI

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
    @State private var appState: AppState
    @State private var preferences = Preferences(store: UserDefaultsPreferenceStore())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // One session manager for the process, made before any scene: the
        // window's AppState runs the session on it, and the notification
        // actions and App Intents, which can run on a launch that never
        // builds a scene, borrow its client rather than build their own.
        let sessions = SessionManager()
        _appState = State(initialValue: AppState(sessionManager: sessions))
        #if os(iOS)
        PushRegistrar.shared.attach(sessions)
        IntentBridge.shared.attach(sessions)
        // The App Intents live in this target, so the shared session
        // lifecycle reaches them through these hooks. Installed here, before
        // the first `.task` can restore a session.
        AppIntentsSessionHooks.sessionDidStart = { appState in
            IntentBridge.shared.sessionDidStart(appState: appState)
            CabalmailAppShortcuts.updateAppShortcutParameters()
        }
        AppIntentsSessionHooks.sessionWillEnd = {
            IntentBridge.shared.sessionWillEnd()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Lets a closing compose window re-activate this scene on
                // iPadOS instead of dropping to the home screen (no-op on
                // other platforms; see MainSceneActivation.swift).
                .recordsMainSceneSession()
                .environment(appState)
                .environment(preferences)
                .themedAppearance(preferences.theme)
                .appRootLifecycle(
                    appState: appState,
                    preferences: preferences,
                    scenePhase: scenePhase,
                    onForeground: {
                        // Re-offer the session to the watch on every return
                        // to the foreground — see
                        // AppState.refreshWatchSession() for why the
                        // launch-time push alone strands a watch app
                        // installed while this app was already running.
                        Task { await appState.refreshWatchSession() }
                    }
                )
                // Gives this window the identity its menu commands are aimed
                // at, so a second window ignores them, and that a link the
                // system aims at it opens in (MainWindowCommandScope). Last,
                // so everything above, the launch chain included, has it.
                .mainWindowCommandScope(appState)
        }
        // Same Message menu the macOS menu bar shows. On iPadOS the
        // commands surface through the hardware-keyboard menu (hold
        // Cmd) so Reply / Mark / Flag / Move get the same chords as
        // the Mac; iPhone carries them inertly.
        .commands {
            MessageMenuCommands()
            FeedsMenuCommands(appState: appState)
            // Settings sheet shortcut. iOS has no Settings scene (macOS owns
            // Cmd+, through its `Settings {}` scene), so we claim the standard
            // app-settings slot and route it to the same tick the sidebar gear
            // bumps. Surfaces in the iPadOS hardware-keyboard menu.
            SettingsMenuCommand(appState: appState)
        }
        // iPadOS, visionOS, and an open iPhone Duo open compose as a real
        // scene; a single-window host ignores the group because
        // `ComposeSurfacePolicy` keeps it on the sheet path. Installing the
        // WindowGroup on every iOS build keeps the scene available the
        // moment the host gains windows (Stage Manager, iPad, unfolding a
        // Duo).
        ComposeWindowScene(appState: appState, preferences: preferences)
    }
}

/// Settings sheet shortcut (⌘,) in the iPadOS hardware-keyboard menu, aimed
/// at the focused main window so a second window does not open its own sheet.
private struct SettingsMenuCommand: Commands {
    let appState: AppState
    @FocusedValue(\.commandWindowID) private var focusedWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                appState.requestSettings(in: appState.menuCommandTarget(focused: focusedWindow))
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
