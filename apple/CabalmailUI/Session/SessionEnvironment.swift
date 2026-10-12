import Foundation
import UserNotifications
import CabalmailKit
import CabalmailShared

// The seams `SessionManager` reaches the world through: the environment its
// lifecycle builds clients in, and the platform hooks a session starts and
// stops. Moved out of `AppState` with the lifecycle (workstream 1.3).

// MARK: - Session environment

/// Everything `SessionManager`'s session lifecycle (sign-in, MFA, restore,
/// sign-out, lending the client) reaches outside the process: the config
/// fetch, the keychain, the client factory, the last-session defaults and
/// the per-platform session hooks. `.live` makes exactly the calls the
/// lifecycle always made; the app-layer tests swap in an environment over
/// in-memory stores and a scripted transport so the lifecycle can be
/// characterized without the network, the keychain, Application Support or
/// OS permission prompts.
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
            makeSecureStore: { liveSecureStore() },
            makeClient: { configuration, secureStore, monitor in
                let cacheDirectory = try liveCacheDirectory()
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

// MARK: - Client construction helpers

extension SessionEnvironment {
    /// The keychain store the session client persists Cognito tokens
    /// through. On iOS and macOS it's wrapped in `PushMirroringSecureStore`
    /// so every token write — sign-in and each silent refresh — also lands
    /// in the shared containers the Notification Service Extension reads
    /// (see `PushEnrichmentStore`).
    static func liveSecureStore() -> SecureStore {
        #if os(iOS) || os(macOS)
        return PushMirroringSecureStore(base: KeychainSecureStore())
        #else
        return KeychainSecureStore()
        #endif
    }

    /// Returns the application-support cache directory for this app, creating
    /// it if needed. Per-folder subdirectories are created by the cache
    /// actors themselves.
    static func liveCacheDirectory() throws -> URL {
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

// MARK: - Session hooks

/// The process-wide services a session starts and stops: push registration,
/// the App Intents bridge, the watch hand-off and the badge and contacts
/// permission requests. `.live` is what `SessionManager`'s wiring and
/// sign-out always called, in the same order.
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
                // Hand the session to the App Intents bridge, whose intents
                // borrow its client, and re-donate the folder-parameterized
                // App Shortcut phrases now that the folder list is reachable.
                // Both live in the app target; see `AppIntentsSessionHooks`.
                // An Open Folder from a cold launch waits in `DeepLinkRouter`.
                AppIntentsSessionHooks.sessionDidStart(appState)
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
                AppIntentsSessionHooks.sessionWillEnd()
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

#if os(iOS)
/// The calls a session's start and end make into the App Intents. Those live
/// in the iOS app target, not in this module, because Siri and Shortcuts read
/// intent metadata from the app's own binary, so this module cannot name
/// them. `CabalmailApp` installs both at launch, before any session can
/// start; until then they do nothing.
@MainActor
public enum AppIntentsSessionHooks {
    /// Hands the new session to the App Intents bridge, and re-donates the
    /// folder-parameterized App Shortcut phrases. An Open Folder parked
    /// before the session waits in `DeepLinkRouter` for a window.
    public static var sessionDidStart: (AppState) -> Void = { _ in }
    /// Detaches the App Intents bridge from the ending session.
    public static var sessionWillEnd: () -> Void = {}
}
#endif
