// App Intents ship on iOS/iPadOS in this wave; the visionOS build of the
// shared Cabalmail target must not compile this (same convention as
// PushRegistrar), and CabalmailMac doesn't list Cabalmail/Intents in its
// sources.
#if os(iOS)
import Foundation
import CabalmailKit

/// Session access for App Intents, modeled on `PushRegistrar`: intents can
/// fire while the app is foregrounded, backgrounded, or not launched at all,
/// so they can't reach the SwiftUI-owned `AppState` through the environment.
///
/// `AppState.wireSession` hands the session in via `sessionDidStart`; when no
/// session is wired (a background intent on a cold process), `activeClient()`
/// bootstraps a client from the persisted control domain and keychain tokens —
/// the same recipe as the push action-handler's cold-launch path.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    /// Set by `sessionDidStart`; navigation targets (`navCoordinator`) hang
    /// off it. Weak — the bridge outlives any session.
    private(set) weak var appState: AppState?

    /// Client bootstrapped for a background intent on a process with no
    /// wired session. Cached so a burst of intents doesn't rebuild it;
    /// dropped as soon as a real session starts or ends.
    private var bootstrapClient: CabalmailClient?

    /// A folder-open request that arrived before sign-in / restore completed
    /// (an OpenFolderIntent cold launch); routed once the session is wired,
    /// mirroring `PushRegistrar.pendingOpen`.
    private var pendingFolderPath: String?

    func sessionDidStart(appState: AppState) {
        self.appState = appState
        bootstrapClient = nil
        if let path = pendingFolderPath {
            pendingFolderPath = nil
            requestOpenFolder(path)
        }
    }

    func sessionWillEnd() {
        appState = nil
        bootstrapClient = nil
        pendingFolderPath = nil
    }

    /// Routes the UI to a folder through the same `navigateRequest`
    /// machinery as a notification tap; `MailRootView` drains a pre-mount
    /// request from its `.task`, so the cold-launch case works too.
    func requestOpenFolder(_ path: String) {
        guard let coordinator = appState?.navCoordinator else {
            pendingFolderPath = path
            return
        }
        coordinator.navigateRequest = NavState(folder: path, clientID: coordinator.clientID)
    }

    /// The session client, or a cached/bootstrapped one when no session is
    /// wired. Auth refresh happens through the normal client path either
    /// way. Throws `IntentError.notSignedIn` when signed out so Siri reads
    /// a sensible sentence instead of a raw error.
    func activeClient() async throws -> CabalmailClient {
        if let client = appState?.client { return client }
        if let bootstrapClient { return bootstrapClient }
        let domain = UserDefaults.standard.string(forKey: "cabalmail.controlDomain") ?? ""
        guard !domain.isEmpty else { throw IntentError.notSignedIn }
        let store = AppState.makeSecureStore()
        guard (try? store.get(SecureStoreKey.authTokens)) != nil else { throw IntentError.notSignedIn }
        do {
            let configuration = try await ConfigLoader.load(controlDomain: domain)
            let client = try CabalmailClient.make(
                configuration: configuration,
                secureStore: store,
                cacheDirectory: AppState.makeCacheDirectory()
            )
            bootstrapClient = client
            return client
        } catch {
            throw IntentError.friendly(error)
        }
    }
}
#endif
