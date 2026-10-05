import Foundation
#if canImport(Network)
import Network
import Synchronization

/// Reachability observer used by the offline banner and the outgoing send
/// queue.
///
/// Exposes the current status plus a stream of changes; the UI and the
/// send queue care only about "is there any usable path."
///
/// Concurrency: `NWPathMonitor` delivers updates on its own queue; the last
/// status and the subscribers' continuations share one `Mutex`, so consumers
/// can read the status or `for await` the stream from any isolation domain.
public final class Reachability: Sendable {
    private struct State {
        var isReachable = true
        var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cabalmail.Reachability")
    private let state = Mutex(State())

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        let observers = state.withLock { state in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in observers {
            continuation.finish()
        }
    }

    public var isReachable: Bool {
        state.withLock { $0.isReachable }
    }

    /// Async stream yielding `true` / `false` on every transition. The
    /// first element is the current value so a consumer that just started
    /// observing can render the right state immediately.
    public func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            // Registered and seeded under the one lock, so a transition can't
            // reach the stream ahead of the value it replaces.
            state.withLock { state in
                state.continuations[id] = continuation
                continuation.yield(state.isReachable)
            }
            // Weak: the continuation stores this handler and `state` stores
            // the continuation, so a strong `self` here keeps a signed-out
            // session's monitor running for as long as anything still holds
            // one of its streams (#1809).
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    /// How many streams are subscribed; for tests.
    var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }

    private func handle(_ path: NWPath) {
        let reachable = path.status == .satisfied
        let observers = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            guard state.isReachable != reachable else { return [] }
            state.isReachable = reachable
            return Array(state.continuations.values)
        }
        for continuation in observers {
            continuation.yield(reachable)
        }
    }

    private func removeContinuation(id: UUID) {
        _ = state.withLock { $0.continuations.removeValue(forKey: id) }
    }
}
#endif
