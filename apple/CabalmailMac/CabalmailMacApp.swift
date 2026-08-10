import SwiftUI
import CoreSpotlight
import CabalmailKit

/// Stable identifier for the main mail window's `WindowGroup`, shared
/// with the menu-bar extra's "Open Cabalmail" item so both target the
/// same scene group.
let mainWindowID = "main"

/// App entry point for the native macOS target.
///
/// Shares the same observable roots as the iOS/iPadOS/visionOS target
/// (`AppState`, `Preferences`) so every scene binds the same backing
/// state. macOS gets the main mail window, the standalone compose scene,
/// a Settings window (⌘,), and an optional menu-bar extra (Mac
/// residency). Address and folder management lives in the main window's
/// mailbox sidebar (`AddressListView` / `FolderListView`), which carries
/// the full request/revoke and create/delete affordances.
@main
struct CabalmailMacApp: App {
    // Push notifications: APNs token callbacks and the notification-center
    // delegate have no SwiftUI-native surface, so the macOS build carries a
    // minimal AppKit delegate — the same AppDelegate.swift source the iOS
    // target compiles, with an NSApplicationDelegate branch (see that file).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var preferences = Preferences(store: UserDefaultsPreferenceStore())
    @Environment(\.scenePhase) private var scenePhase
    // Mac residency: whether the status-item menu is installed. Backed by
    // UserDefaults so the "Show in menu bar" toggle in Settings >
    // Notifications inserts/removes the item live via `isInserted`.
    @AppStorage(menuBarExtraDefaultsKey) private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup("Cabalmail", id: mainWindowID) {
            ContentView()
                .environment(appState)
                .environment(preferences)
                .preferredColorScheme(colorScheme(for: preferences.theme))
                .task {
                    // Hand the app-root Preferences to AppState before any
                    // restore so the session's PreferencesSyncCoordinator can
                    // pull the server copy (server wins on login).
                    appState.usePreferences(preferences)
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
                .onChange(of: scenePhase) { _, phase in
                    // Pick up settings changed on another device while this
                    // window was in the background (server wins, unless a
                    // local edit is still pending its push).
                    guard phase == .active else { return }
                    Task { await appState.prefsCoordinator?.reconcile() }
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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A tapped Spotlight result. Parks on AppState until the
                    // session is wired when it arrives via cold launch (see
                    // SpotlightRouting.swift).
                    appState.handleSpotlightActivity(activity)
                }
        }
        // A WindowGroup's default reaction to an external event (an
        // incoming mailto: URL) is to *spawn a fresh window of the
        // group* to receive it — so a mailto: click used to open a
        // spurious second main window alongside the compose window the
        // handler above requests. An empty matching set disables that
        // new-window spawning; `.onOpenURL` is still delivered to the
        // existing main window, which is what we want.
        .handlesExternalEvents(matching: [])
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
        // Menu-bar presence (Mac residency). Enriched notifications need
        // the app process alive (silent-push design, see
        // docs/push-notifications.md); the status item keeps that
        // residency legible and useful. `.menu` style: plain menu items,
        // no custom panel. MenuBarMark is the brand mark on a 32x16pt
        // canvas (generated by scripts/generate-logo-assets), template-
        // rendered so the menu bar recolors it per appearance.
        MenuBarExtra(
            "Cabalmail",
            image: "MenuBarMark",
            isInserted: $showMenuBarExtra
        ) {
            MenuBarExtraMenu()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)
    }

    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
