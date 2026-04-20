import Foundation

/// High-level IMAP operations used by the rest of the Apple client.
///
/// The `LiveImapClient` implementation opens one long-lived authenticated
/// `ImapConnection` for command traffic; IDLE takes a dedicated second
/// connection so ongoing foreground sync doesn't block mailbox operations
/// (replies, folder switches).
///
/// Folder paths in this API use `/` as the delimiter regardless of the
/// server's native separator (Dovecot's is `.`). `LiveImapClient` performs
/// the translation at the boundary, mirroring the `list_folders` Lambda's
/// `.replace("/", ".")` normalization (see `lambda/api/python/python/helper.py`).
public protocol ImapClient: Sendable {
    func connectAndAuthenticate() async throws
    func listFolders() async throws -> [Folder]
    func createFolder(name: String, parent: String?) async throws
    func deleteFolder(path: String) async throws
    func subscribe(path: String) async throws
    func unsubscribe(path: String) async throws
    func status(path: String) async throws -> FolderStatus
    func envelopes(folder: String, range: ClosedRange<UInt32>) async throws -> [Envelope]
    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage
    func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data
    func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws
    func move(folder: String, uids: [UInt32], destination: String) async throws
    func search(folder: String, query: String) async throws -> [UInt32]
    func append(folder: String, message: Data, flags: Set<Flag>) async throws
    func disconnect() async

    /// Drops any cached connection so the next command reconnects. Used by
    /// `CabalmailClient`'s network-path monitor to purge sockets established
    /// against a prior network (sleep/wake, WiFi↔cellular handoff).
    func invalidate() async

    /// Opens an IDLE stream for `folder` and yields `IdleEvent`s until
    /// cancelled. Implementations without a live server (unit-test mocks,
    /// in-memory fakes) can return an empty stream — `MailboxWatcher` treats
    /// an immediately-finished stream as a clean exit and backs off, which
    /// is the right behavior for those transports.
    ///
    /// Phase 7 wires `MessageListViewModel` into the resulting stream so a
    /// server-initiated EXISTS / EXPUNGE / FETCH triggers an envelope
    /// refresh. The watcher itself holds the reconnect / backoff policy.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error>
}

public extension ImapClient {
    /// Default implementation used by test doubles and any client that
    /// doesn't yet support IDLE. Returning an immediately-finished stream
    /// means the watcher yields one `.active` event and then sits in the
    /// reconnect backoff — cheap, correct, and no per-mock boilerplate.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Opens a second connection for IDLE and yields untagged events until the
/// returned stream is cancelled. See `LiveImapClient.idle(folder:)`.
public struct IdleEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case exists(UInt32)
        case expunge(UInt32)
        case fetch(UInt32)
    }
    public let kind: Kind
}

/// Dependency used by `LiveImapClient` to open connections. Tests inject a
/// factory that returns a `ByteStream` preloaded with scripted server
/// responses; production code builds a `NetworkByteStream` on port 993.
public protocol ImapConnectionFactory: Sendable {
    func makeConnection() async throws -> ByteStream
}

#if canImport(Network)
/// Production factory that opens a TLS-wrapped `NetworkByteStream` against
/// the configured `host`.
public struct NetworkImapConnectionFactory: ImapConnectionFactory {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    public func makeConnection() async throws -> ByteStream {
        let stream = NetworkByteStream(host: host, port: port, useTLS: true)
        try await stream.start()
        return stream
    }
}
#endif
