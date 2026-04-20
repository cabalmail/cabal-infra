import Foundation
#if canImport(Network)
@preconcurrency import Network

/// Reachability observer used by the offline banner and the outgoing send
/// queue.
///
/// `NetworkPathMonitor` already tracks path *transitions* for socket
/// invalidation; `Reachability` sits alongside it and exposes current
/// status + a stream of changes for UI and the send queue. Splitting the
/// two keeps each surface narrowly focused — socket invalidation wants a
/// gateway-or-interface-level signal, UI cares only about "is there any
/// usable path."
///
/// Concurrency: `NWPathMonitor` delivers updates on its own queue; this
/// class stores the last status under a lock and yields it into the
/// Sendable stream continuations so consumers can `for await` it from any
/// isolation domain.
public final class Reachability: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cabalmail.Reachability")
    private let lock = NSLock()
    private var _isReachable = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        lock.lock()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        lock.unlock()
    }

    public var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReachable
    }

    /// Async stream yielding `true` / `false` on every transition. The
    /// first element is the current value so a consumer that just started
    /// observing can render the right state immediately.
    public func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            let initial = _isReachable
            continuations[id] = continuation
            lock.unlock()
            continuation.yield(initial)
            continuation.onTermination = { @Sendable _ in
                self.removeContinuation(id: id)
            }
        }
    }

    private func handle(_ path: NWPath) {
        let reachable = path.status == .satisfied
        lock.lock()
        let changed = _isReachable != reachable
        _isReachable = reachable
        let observers = Array(continuations.values)
        lock.unlock()
        guard changed else { return }
        for continuation in observers {
            continuation.yield(reachable)
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
#endif
