import SwiftUI
import CabalmailKit
import CabalmailUI

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
    @State private var appState: AppState
    @State private var preferences = Preferences(store: UserDefaultsPreferenceStore())
    @Environment(\.scenePhase) private var scenePhase
    // Mac residency: whether the status-item menu is installed. Backed by
    // UserDefaults so the "Show in menu bar" toggle in Settings >
    // Notifications inserts/removes the item live via `isInserted`.
    @AppStorage(menuBarExtraDefaultsKey) private var showMenuBarExtra = true

    init() {
        // AppKit puts the main window's saved divider positions back before
        // any of its SwiftUI content exists, and puts the message list's back
        // wrong. The columns persist their own widths instead, so AppKit's
        // copy has to be gone before the first window is built. See
        // `SplitViewAutosave`.
        SplitViewAutosave.clearSavedFrames(windowGroupID: mainWindowID)
        // One session manager for the process, made before any scene: the
        // window's AppState runs the session on it, and the notification
        // actions and silent-push enrichment borrow its client rather than
        // build their own.
        let sessions = SessionManager()
        _appState = State(initialValue: AppState(sessionManager: sessions))
        PushRegistrar.shared.attach(sessions)
    }

    var body: some Scene {
        WindowGroup("Cabalmail", id: mainWindowID) {
            ContentView()
                // Gives this window the identity its menu commands are aimed
                // at, so a second window ignores them (MainWindowCommandScope).
                .mainWindowCommandScope(appState)
                .environment(appState)
                .environment(preferences)
                .themedAppearance(preferences.theme)
                .appRootLifecycle(
                    appState: appState,
                    preferences: preferences,
                    scenePhase: scenePhase,
                    beforeRestore: {
                        // Give the AppKit delegate's Spotlight-continuation
                        // bridge its AppState before the restore suspends —
                        // a cold launch from a Spotlight result parks its
                        // activity in the router until this runs.
                        SpotlightRouter.shared.attach(appState)
                        // Warm the "Open in Private Window" availability
                        // cache so the first link menu of the session lays
                        // out with its rows decided (see PrivateLinkHandoff).
                        PrivateLinkHandoff.prime()
                    }
                )
        }
        // A WindowGroup's default reaction to an external event (an
        // incoming mailto: URL) is to *spawn a fresh window of the
        // group* to receive it — so a mailto: click used to open a
        // spurious second main window alongside the compose window the
        // root's `.onOpenURL` (in `appRootLifecycle`) requests. An empty
        // matching set disables that
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
                .themedAppearance(preferences.theme)
                // Wide enough for the category sidebar plus a detail form
                // (the rules list needs ~560pt of detail width).
                .frame(minWidth: 760, minHeight: 640)
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
}
