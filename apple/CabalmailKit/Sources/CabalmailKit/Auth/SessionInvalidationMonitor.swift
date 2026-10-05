import Foundation
import Synchronization

/// One-way announcement that the stored session is dead.
///
/// Two production sites mint `CabalmailError.authExpired` — Cognito refusing
/// a refresh (`CognitoAuthService.refresh(using:)`, which is where a request
/// that cannot even mint a token dies) and a second 401 on a replayed request
/// (`URLSessionApiClient.retryAfterAuthRefresh`). Both only `throw`, so the
/// fact lands in whichever view model made the call and is rendered there as a
/// sentence; nothing tells the app the session is over, and a running app
/// keeps serving cached mail while Settings still reports "Signed in"
/// (issue #1703). This monitor carries that fact out of the call stack so the
/// session can be torn down once, centrally, rather than at every call site.
///
/// The throws stay — this is additive, and every existing error path keeps its
/// behaviour. It is the Apple twin of Android's `AppContainer.authExpired`
/// flow (issue #1476).
///
/// Concurrency follows `Reachability`: the continuations live in a `Mutex`,
/// so any isolation domain can yield into them.
public final class SessionInvalidationMonitor: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init() {}

    deinit {
        let observers = continuations.withLock { continuations in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in observers {
            continuation.finish()
        }
    }

    /// Async stream yielding once per invalidation. Unlike `Reachability`
    /// there is no current value to replay: expiry is an event, and a
    /// consumer that starts observing afterwards has already been torn down
    /// by whoever was listening at the time.
    public func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            // Weak, as in `Reachability`: the continuation stores this
            // handler, so a strong `self` keeps the monitor alive for as long
            // as a subscriber holds the stream (#1809).
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    /// Announces that the session is over. Called immediately before the
    /// `.authExpired` throw it accompanies, never on the silent-refresh path
    /// (a 401 that a refresh cures) — a signal there would sign the user out
    /// mid-session.
    public func sessionDidExpire() {
        let observers = continuations.withLock { Array($0.values) }
        for continuation in observers {
            continuation.yield(())
        }
    }

    /// How many streams are subscribed; for tests.
    var subscriberCount: Int {
        continuations.withLock { $0.count }
    }

    private func removeContinuation(id: UUID) {
        _ = continuations.withLock { $0.removeValue(forKey: id) }
    }
}
