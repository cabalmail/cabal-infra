import SwiftUI
import CoreSpotlight
import CabalmailKit

/// The launch and lifecycle chain both app entries hang on their main
/// window's root, so the two can't drift: hand `Preferences` to the session
/// and restore it, keep crash reporting following the client, flush and
/// refresh on scene-phase changes, and route `mailto:` links and Spotlight
/// results. What only one entry does comes in as parameters.
///
/// Declares no scene, and leaves the theme to each entry's own
/// `.themedAppearance`: a scene is its own appearance root (#1460).
struct AppRootLifecycle: ViewModifier {
    /// The main window this chain hangs on (`mainWindowCommandScope`, which
    /// each entry applies outside it), so a Spotlight result opens here.
    @Environment(\.commandWindowID) private var windowID
    let appState: AppState
    let preferences: Preferences
    /// The entry's scene phase, which is the app's: active while any of its
    /// scenes is. Passed in rather than read here, where it would be this
    /// window's alone.
    let scenePhase: ScenePhase
    /// Runs at launch once `Preferences` is handed in, before the restore
    /// suspends.
    let beforeRestore: @MainActor () -> Void
    /// Runs first on each return to the foreground.
    let onForeground: @MainActor () -> Void

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
            .onChange(of: scenePhase) { _, phase in
                // Leaving the foreground: write the local resume session
                // now, so a debounce in flight isn't lost if the process
                // is terminated while backgrounded.
                if phase != .active { appState.navCoordinator?.flushSession() }
                guard phase == .active else { return }
                onForeground()
                // Pick up settings changed on another device while the app
                // was in the background (server wins, unless a local edit is
                // still pending its push).
                Task { await appState.prefsCoordinator?.reconcile() }
                // Feeds: fresh items and the offline mutation queue.
                Task { await appState.refreshFeedsOnForeground() }
            }
            .onOpenURL { url in
                // mailto: links, from other apps once Cabalmail is the
                // default mail app, and on a cold launch before any view is
                // wired to observe `composeRequestTick`: the seed parks on
                // `AppState.pendingComposeSeed` until `ComposeRequestRouter`
                // drains it.
                if let mailto = MailtoURL(url) {
                    appState.requestCompose(seed: mailto.draft(), in: appState.lastActiveMainWindow)
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
    /// (`AppRootLifecycle`), with the entry's own launch and foreground
    /// steps.
    public func appRootLifecycle(
        appState: AppState,
        preferences: Preferences,
        scenePhase: ScenePhase,
        beforeRestore: @escaping @MainActor () -> Void = {},
        onForeground: @escaping @MainActor () -> Void = {}
    ) -> some View {
        modifier(AppRootLifecycle(
            appState: appState,
            preferences: preferences,
            scenePhase: scenePhase,
            beforeRestore: beforeRestore,
            onForeground: onForeground
        ))
    }
}
