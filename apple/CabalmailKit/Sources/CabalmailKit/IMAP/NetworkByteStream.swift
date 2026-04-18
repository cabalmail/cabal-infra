import Foundation
#if canImport(Network)
@preconcurrency import Network

/// Production `ByteStream` built on `Network.framework`'s `NWConnection`.
///
/// `NWConnection` is inherently thread-safe (Apple guarantees serial access
/// to its callbacks via the queue it owns), so this type is marked
/// `@unchecked Sendable` — the actor we feed it to (`ImapConnection`) will
/// serialize logical access, and the underlying connection serializes the
/// I/O.
public final class NetworkByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let host: String
    private let queue = DispatchQueue(label: "com.cabalmail.NetworkByteStream")

    /// Opens a TCP connection. Pass `useTLS: true` for IMAPS (993) and
    /// implicit-TLS SMTP (465); use the plain path + `startTLS(host:)` when
    /// STARTTLS is required (not currently supported — see `startTLS`).
    public init(host: String, port: UInt16, useTLS: Bool) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options())
        } else {
            parameters = NWParameters.tcp
        }
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.host = host
    }

    public func start() async throws {
        let guardFlag = ResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardFlag.tryFire() { continuation.resume() }
                case .failed(let error):
                    if guardFlag.tryFire() {
                        continuation.resume(throwing: CabalmailError.network(error.localizedDescription))
                    }
                case .cancelled:
                    if guardFlag.tryFire() {
                        continuation.resume(throwing: CabalmailError.cancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: CabalmailError.transport(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: CabalmailError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// STARTTLS is not implemented on `NetworkByteStream`: `NWConnection`'s
    /// TLS stack attaches at connect time and cannot be retrofitted mid-
    /// stream without a custom framer. For submission, configure port 465
    /// with `useTLS: true` instead — the Cabalmail SMTP out tier listens on
    /// both 587 and 465 (see `terraform/infra/modules/elb/main.tf`), and the
    /// wire auth flow is otherwise identical.
    public func startTLS(host: String) async throws -> ByteStream {
        throw CabalmailError.protocolError(
            "STARTTLS not supported on NetworkByteStream; use implicit TLS (port 465) instead"
        )
    }

    public func close() async {
        connection.cancel()
    }
}

/// One-shot resume guard: ensures a `CheckedContinuation` is resumed exactly
/// once despite Network framework state handlers firing multiple times.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
#endif
