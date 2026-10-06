// App Intents ship on iOS/iPadOS in this wave; the visionOS build of the
// shared Cabalmail target must not compile this (same convention as
// PushRegistrar), and CabalmailMac doesn't list Cabalmail/Intents in its
// sources.
#if os(iOS)
import Foundation
import CabalmailKit
import CabalmailUI

/// Session access for App Intents, modeled on `PushRegistrar`: intents can
/// fire while the app is foregrounded, backgrounded, or not launched at all,
/// so they can't reach the SwiftUI-owned `AppState` through the environment.
///
/// Intents borrow the session manager's client (`SessionManager.borrowClient()`):
/// the wired session's, or on a cold background launch the stored account's,
/// which the manager builds once, from the cached config.json and with the
/// expiry monitor, and which the next launch restore adopts. `CabalmailApp`
/// hands the manager in before any scene exists. The session's start and end
/// reach the bridge through `AppIntentsSessionHooks`.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    /// The process's session manager, handed in by `CabalmailApp.init`.
    private var sessions: SessionManager?

    /// Set by `sessionDidStart`; navigation targets (`navCoordinator`) hang
    /// off it. Weak — the bridge outlives any session.
    private(set) weak var appState: AppState?

    /// A folder-open request that arrived before sign-in / restore completed
    /// (an OpenFolderIntent cold launch); routed once the session is wired,
    /// mirroring `PushRegistrar.pendingOpen`.
    private var pendingFolderPath: String?

    /// Called once, before any scene and so before any intent can run.
    func attach(_ sessions: SessionManager) {
        self.sessions = sessions
    }

    func sessionDidStart(appState: AppState) {
        self.appState = appState
        if let path = pendingFolderPath {
            pendingFolderPath = nil
            requestOpenFolder(path)
        }
    }

    func sessionWillEnd() {
        appState = nil
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

    /// The client an intent works through, borrowed from the session manager.
    /// Auth refresh happens through the normal client path. Throws
    /// `IntentError.notSignedIn` when signed out, so Siri reads a sensible
    /// sentence instead of a raw error, and a friendly wrapper of whatever
    /// building the client threw.
    func activeClient() async throws -> CabalmailClient {
        let borrowed: CabalmailClient?
        do {
            borrowed = try await sessions?.borrowClient()
        } catch {
            throw IntentError.friendly(error)
        }
        guard let borrowed else { throw IntentError.notSignedIn }
        return borrowed
    }
}
#endif
