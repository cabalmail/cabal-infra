import Foundation
#if canImport(Network)
@preconcurrency import Network

/// Observes network path changes via `NWPathMonitor` and fires `onChange`
/// when the active path shifts in a way that likely invalidates long-lived
/// sockets — different interface, gained/lost connectivity, or a new set of
/// gateways (e.g. switching WiFi networks on the same interface).
///
/// The first path delivery after `start()` is the current baseline and does
/// not fire the handler — callers only care about transitions away from the
/// state that was in effect when they opened their sockets.
///
/// `NWPathMonitor` invokes its handler on the provided queue; this wrapper
/// forwards to `onChange` on the same queue. Consumers should hop into the
/// right isolation domain inside the handler (typically a `Task { ... }`).
public final class NetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cabalmail.NetworkPathMonitor")
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var previous: Signature?

    /// Coarse identity of a path. Equal signatures are treated as "no
    /// material change"; inequality triggers `onChange`. Gateways change on
    /// WiFi-network switches even when the interface name stays the same,
    /// which is the common Mac sleep/wake pattern we're guarding against.
    private struct Signature: Equatable {
        let status: NWPath.Status
        let interfaces: [String]
        let gateways: [String]
    }

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func handle(_ path: NWPath) {
        let signature = Signature(
            status: path.status,
            interfaces: path.availableInterfaces.map { $0.name },
            gateways: path.gateways.map { "\($0)" }
        )
        let shouldFire: Bool
        lock.lock()
        if let previous, previous == signature {
            shouldFire = false
        } else {
            shouldFire = previous != nil
            previous = signature
        }
        lock.unlock()
        if shouldFire {
            onChange()
        }
    }
}
#endif
