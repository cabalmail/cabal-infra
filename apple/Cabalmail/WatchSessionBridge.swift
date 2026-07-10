// Phone side of the watch credential hand-off.
//
// WatchConnectivity exists on iOS (and watchOS) only, so the real
// implementation compiles solely into the iOS slice; visionOS builds of
// this target and the macOS target (which shares AppState.swift and this
// file) get the no-op stub below. Same API either way, which keeps the
// AppState call-sites free of per-platform conditionals.
#if canImport(WatchConnectivity) && os(iOS)
import CabalmailKit
import Foundation
import WatchConnectivity

/// Pushes the signed-in session (Configuration + Cognito tokens + username)
/// to the paired watch via the WCSession application context, and a
/// versioned "signed out" context on sign-out. Application-context delivery
/// is latest-state: the watch receives whatever was pushed most recently the
/// next time it wakes, even if both apps were dead in between — exactly the
/// semantics a credential hand-off wants.
///
/// Failures are deliberately quiet. There is no user-visible surface for
/// "the watch didn't get the tokens yet": every sign-in / restore pushes a
/// fresh context, and the watch shows its own "connect from your iPhone"
/// state until one arrives.
final class WatchSessionBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionBridge()

    /// Context waiting for session activation to complete. Guarded by
    /// `lock` — delegate callbacks arrive on WatchConnectivity's own queue.
    private let lock = NSLock()
    private var pendingContext: [String: Any]?

    func pushSession(configuration: Configuration, tokens: AuthTokens, username: String) {
        let handoff = WatchHandoff(
            configuration: configuration,
            tokens: tokens,
            username: username
        )
        guard let context = try? handoff.applicationContext() else { return }
        push(context)
    }

    func pushSignedOut() {
        push(WatchHandoff.signedOutContext())
    }

    private func push(_ context: [String: Any]) {
        // isSupported is false on iPad — only iPhones pair with a watch.
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .activated {
            try? session.updateApplicationContext(context)
        } else {
            lock.lock()
            pendingContext = context
            lock.unlock()
            session.activate()
        }
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        lock.lock()
        let context = pendingContext
        pendingContext = nil
        lock.unlock()
        if let context {
            try? session.updateApplicationContext(context)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Apple's contract for the user switching to a different paired
        // watch: reactivate so the new watch keeps receiving contexts.
        session.activate()
    }
}
#else
import CabalmailKit

/// No-op stand-in for platforms without WatchConnectivity — only iPhones
/// pair with a watch, so there is nothing to hand off elsewhere.
final class WatchSessionBridge: Sendable {
    static let shared = WatchSessionBridge()

    func pushSession(configuration: Configuration, tokens: AuthTokens, username: String) {}
    func pushSignedOut() {}
}
#endif
