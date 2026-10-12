import SwiftUI
import CoreSpotlight
import CabalmailKit

/// The launch and lifecycle chain both app entries hang on their main
/// window's root, so the two can't drift: hand `Preferences` to the session
/// and restore it, keep crash reporting following the client, and route
/// `mailto:` links and Spotlight results. What only one entry does comes in
/// as a parameter. What the app does as it leaves and returns to the
/// foreground is not a window's: each entry's scene-level handler calls
/// `AppState.appScenePhaseChanged(to:)` once.
///
/// Declares no scene, and leaves the theme to each entry's own
/// `.themedAppearance`: a scene is its own appearance root (#1460).
struct AppRootLifecycle: ViewModifier {
    /// The main window this chain hangs on (`mainWindowCommandScope`, which
    /// each entry applies outside it), so a Spotlight result opens here.
    @Environment(\.commandWindowID) private var windowID
    let appState: AppState
    let preferences: Preferences
    /// Runs at launch once `Preferences` is handed in, before the restore
    /// suspends.
    let beforeRestore: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .task {
                // Hand the app-root Preferences to AppState before any
                // restore so the session's PreferencesSyncCoordinator can
                // pull the server copy (server wins on login).
                appState.usePreferences(preferences)
                beforeRestore()
                // Launch-time auto-restore. `restoreIfPossible()` is a
                // no-op once the user is signed in, so SwiftUI re-running
                // this `.task` across scene re-attaches (e.g. on resume)
                // stays cheap.
                await appState.restoreIfPossible()
                // Opt-in MetricKit needs to register as a subscriber *early*
                // in the launch, or diagnostic payloads from the last
                // session won't be delivered. Re-running on every `.task`
                // firing is safe because `start()` is idempotent.
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
                // mailto: links, from other apps once Cabalmail is the
                // default mail app. The composer opens in the main window
                // last used; on a cold launch, or while signed out, the
                // seed waits with `ComposeCoordinator` for the first window
                // that can show it.
                if let mailto = MailtoURL(url) {
                    appState.compose.open(seed: mailto.draft(), from: appState.lastActiveMainWindow)
                }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                // A tapped Spotlight result opens in this window, or parks
                // for it until the session is wired on a cold launch (see
                // SpotlightRouting.swift). macOS never delivers it here; its
                // path is the app delegate's.
                appState.handleSpotlightActivity(activity, in: windowID)
            }
    }
}

extension View {
    /// The main window root's launch and lifecycle chain
    /// (`AppRootLifecycle`), with the entry's own launch step.
    public func appRootLifecycle(
        appState: AppState,
        preferences: Preferences,
        beforeRestore: @escaping @MainActor () -> Void = {}
    ) -> some View {
        modifier(AppRootLifecycle(appState: appState, preferences: preferences, beforeRestore: beforeRestore))
    }
}
