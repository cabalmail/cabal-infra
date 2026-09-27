import Foundation
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
    func observeSessionInvalidation() {
        sessionExpiryTask?.cancel()
        let invalidation = sessionInvalidation
        sessionExpiryTask = Task { [weak self] in
            for await _ in invalidation.events() {
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
