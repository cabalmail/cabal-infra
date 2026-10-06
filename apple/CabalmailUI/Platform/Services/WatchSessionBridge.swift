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

    /// Guarded by `lock` — delegate callbacks arrive on WatchConnectivity's
    /// own queue. `pendingContext` waits for session activation to complete;
    /// `lastContext` is re-offered when the watch state changes (e.g. the
    /// watch app was just installed), so a watch that arrives after the
    /// phone's launch-time push doesn't sit waiting for the next cold start.
    private let lock = NSLock()
    private var pendingContext: [String: Any]?
    private var lastContext: [String: Any]?

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
            lock.lock()
            lastContext = context
            lock.unlock()
            try? session.updateApplicationContext(context)
        } else {
            lock.lock()
            pendingContext = context
            lastContext = context
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

    func sessionWatchStateDidChange(_ session: WCSession) {
        // Fires when pairing / watch-app-install state changes. The case
        // that matters: the watch app was just installed while this app was
        // already running, so the launch-time push predates the watch's
        // existence. Re-offer the current session immediately rather than
        // leaving the watch on its "open Cabalmail on your iPhone" screen
        // until the phone's next cold start.
        guard session.activationState == .activated else { return }
        lock.lock()
        let context = lastContext
        lock.unlock()
        if let context {
            try? session.updateApplicationContext(context)
        }
    }

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
