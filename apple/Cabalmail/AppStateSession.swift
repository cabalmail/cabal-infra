import Foundation
import UserNotifications
import CabalmailKit

// MARK: - Session lifecycle
//
// How a session's client is built, and how a session ends when the server
// stops honouring it. Split out of `AppState.swift` to keep that file under
// SwiftLint's `file_length` cap, alongside the feeds / search / subscription
// extensions.

@MainActor
extension AppState {
    /// Watch for this install's credentials being refused, for the life of
    /// the session. Replaces any previous observer, so signing back in does
    /// not leave two running. Called from `wireSession`, which is the one
    /// place both entry paths (sign-in, restore) pass through.
    ///
    /// Subscribes here, not inside the task. The task's body waits for the
    /// main actor's next turn — at launch that can be long enough for a
    /// restore's first call to die of the refresh — and the monitor has no
    /// replay, so a signal in that gap found no listener and the app stayed
    /// signed in. Registered now, it is buffered until the loop drains it.
    func observeSessionInvalidation() {
        sessionExpiryTask?.cancel()
        let events = sessionInvalidation.events()
        sessionExpiryTask = Task { [weak self] in
            for await _ in events {
                await self?.handleSessionExpiry()
            }
        }
    }

    /// Drop a session the server has stopped honouring, while the app is up.
    ///
    /// Before this existed, an expiry mid-session only ever became the *text*
    /// of whichever call happened to fail: the app stayed in the mail shell
    /// serving cached content and Settings ▸ Account still read "Signed in",
    /// because `restore()` was the only code that translated an expired
    /// session into a status change (issue #1703). Routed through `signOut()`
    /// so there is exactly one teardown rather than two that can drift — the
    /// difference is the reason, which the sign-in form then explains.
    ///
    /// Idempotent via the status check: the Kit announces once per
    /// invalidation, but a signal that lands after the user has already
    /// signed out must not put "your session expired" on a form they asked
    /// for.
    func handleSessionExpiry() async {
        guard status != .signedOut else { return }
        await signOut()
        signedOutReason = .sessionExpired
    }

}

// MARK: - Client construction helpers

extension AppState {
    /// The keychain store the session client persists Cognito tokens
    /// through. On iOS and macOS it's wrapped in `PushMirroringSecureStore`
    /// so every token write — sign-in and each silent refresh — also lands
    /// in the shared containers the Notification Service Extension reads
    /// (see `PushEnrichmentStore`). Static (and non-private) so the push
    /// action-handler's cold-launch bootstrap builds an identical stack.
    static func makeSecureStore() -> SecureStore {
        #if os(iOS) || os(macOS)
        return PushMirroringSecureStore(base: KeychainSecureStore())
        #else
        return KeychainSecureStore()
        #endif
    }

    /// Returns the application-support cache directory for this app, creating
    /// it if needed. Per-folder subdirectories are created by the cache
    /// actors themselves. Static for the same bootstrap reason as
    /// `makeSecureStore`.
    static func makeCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Cabalmail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Session environment

/// Everything `AppState`'s session lifecycle (sign-in, MFA, restore,
/// sign-out) reaches outside the process: the config fetch, the keychain,
/// the client factory, the last-session defaults and the per-platform
/// session hooks. `.live` makes exactly the calls the lifecycle always made;
/// the app-layer tests swap in an environment over in-memory stores and a
/// scripted transport so the lifecycle can be characterized without the
/// network, the keychain, Application Support or OS permission prompts.
@MainActor
struct SessionEnvironment {
    /// `config.json` for a control domain, through the last-good cache.
    var loadConfiguration: @MainActor (_ controlDomain: String) async throws -> Configuration
    /// The store the session's Cognito tokens persist through.
    var makeSecureStore: @MainActor () -> SecureStore
    /// The session client over a configuration and secure store, reporting
    /// refused credentials to the monitor.
    var makeClient: @MainActor (
        Configuration, SecureStore, SessionInvalidationMonitor
    ) throws -> CabalmailClient
    var makeNavCoordinator: @MainActor (CabalmailClient) -> NavStateCoordinator
    /// Where the last control domain and username persist.
    var lastSessionDefaults: UserDefaults
    /// Mirrors the control domain to the embedded Safari extension.
    var publishControlDomain: @MainActor (String) -> Void
    var hooks: SessionHooks

    static var live: SessionEnvironment {
        SessionEnvironment(
            loadConfiguration: { try await ConfigLoader.load(controlDomain: $0, cache: ConfigurationCache()) },
            makeSecureStore: { AppState.makeSecureStore() },
            makeClient: { configuration, secureStore, monitor in
                let cacheDirectory = try AppState.makeCacheDirectory()
                return try CabalmailClient.make(
                    configuration: configuration,
                    secureStore: secureStore,
                    cacheDirectory: cacheDirectory,
                    sessionInvalidation: monitor
                )
            },
            makeNavCoordinator: { NavStateCoordinator(client: $0) },
            lastSessionDefaults: .standard,
            publishControlDomain: { ExtensionControlDomainStore.publish($0) },
            hooks: .live
        )
    }
}

/// The process-wide services a session starts and stops: push registration,
/// the App Intents bridge, the watch hand-off and the badge and contacts
/// permission requests. `.live` is what `wireSession` and `signOut` always
/// called, in the same order.
@MainActor
struct SessionHooks {
    /// After the session is wired and `.signedIn` is set.
    var sessionDidStart: @MainActor (AppState, CabalmailClient) -> Void
    /// Before the local wipe, while the tokens still authenticate
    /// (`/push_deregister` needs them).
    var sessionWillEnd: @MainActor () async -> Void
    /// After the tokens are gone.
    var sessionDidEnd: @MainActor () -> Void
    var pushSessionToWatch: @MainActor (Configuration, AuthTokens, String) -> Void
    var requestBadgeAuthorization: @MainActor () -> Void
    var requestContactsAccess: @MainActor (ContactsStore) -> Void

    static var live: SessionHooks {
        SessionHooks(
            sessionDidStart: { appState, client in
                #if os(iOS) || os(macOS)
                // Runs on both entry paths, so every launch re-registers the APNs
                // token — `/push_register` upserts, making this a cheap refresh of
                // the row's `last_seen_at`.
                PushRegistrar.shared.sessionDidStart(appState: appState, client: client)
                #endif
                #if os(iOS)
                // Hand the session to the App Intents bridge (replays a parked
                // OpenFolderIntent from a cold launch) and re-donate the
                // folder-parameterized App Shortcut phrases now that the folder
                // list is reachable.
                IntentBridge.shared.sessionDidStart(appState: appState)
                CabalmailAppShortcuts.updateAppShortcutParameters()
                #endif
            },
            sessionWillEnd: {
                #if os(iOS) || os(macOS)
                // Deregister the APNs token while the Cognito session still works —
                // `/push_deregister` is an authenticated call like every other, and
                // `authService.signOut()` wipes the tokens after this.
                await PushRegistrar.shared.sessionWillEnd()
                #endif
                #if os(iOS)
                IntentBridge.shared.sessionWillEnd()
                #endif
            },
            sessionDidEnd: {
                // Tell the watch to drop its copy of the credentials too.
                WatchSessionBridge.shared.pushSignedOut()
            },
            pushSessionToWatch: { configuration, tokens, username in
                WatchSessionBridge.shared.pushSession(configuration: configuration, tokens: tokens, username: username)
            },
            requestBadgeAuthorization: {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
                }
            },
            requestContactsAccess: { store in
                Task {
                    _ = await store.requestAccess()
                }
            }
        )
    }
}
