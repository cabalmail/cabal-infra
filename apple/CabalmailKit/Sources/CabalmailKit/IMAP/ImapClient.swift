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
    func envelopes(
        folder: String,
        range: ClosedRange<UInt32>,
        sort: SortCriterion
    ) async throws -> [Envelope]

    /// Fetches up to `limit` most-recent envelopes by sequence number. Use
    /// this for the first/top page of a folder — a UID range window can
    /// return fewer envelopes than requested when UIDs are sparse after
    /// expunges (long-lived Inboxes with mixed archive/delete traffic
    /// routinely hit this), because the window `(UIDNEXT - N)...UIDNEXT`
    /// assumes UIDs are dense. Sequence numbers are always contiguous, so
    /// `(totalMessages - limit + 1):*` always yields up to `limit` actual
    /// messages. `totalMessages` comes from a prior `STATUS` (MESSAGES) or
    /// `SELECT`'s EXISTS response; a count of 0 returns `[]` without
    /// touching the wire.
    func topEnvelopes(
        folder: String,
        limit: UInt32,
        totalMessages: UInt32,
        sort: SortCriterion
    ) async throws -> [Envelope]
    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage
    func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data
    func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws
    func move(folder: String, uids: [UInt32], destination: String) async throws

    /// Permanently deletes (expunges) the given messages. The backing
    /// `/purge_messages` Lambda only accepts trash folders, so callers
    /// should gate this on the folder being Trash. The default extension
    /// throws `protocolError`; the API-backed implementation overrides it
    /// (same pattern as `searchEnvelopes`).
    func purge(folder: String, uids: [UInt32]) async throws

    /// Permanently deletes every message in a trash folder (backed by
    /// `/empty_trash`, same trash-only restriction and default).
    func emptyTrash(folder: String) async throws

    /// Structured search across one folder (`query.folder` set) or every
    /// subscribed folder (`query.folder == nil`). Returns envelopes with
    /// their source folder attached, plus the pagination cursor required
    /// to fetch the next page. The wire path is one round trip — no
    /// post-fetch UID range expansion at the call site.
    ///
    /// The default extension throws `protocolError`; the API-backed
    /// implementation overrides it. `LiveImapClient` inherits the
    /// default — production traffic never goes through it (see the
    /// CLAUDE.md note on `ApiBackedImapClient`).
    func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult

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
    /// Convenience overload — delegates to the sorted variant with
    /// `SortCriterion.default` (REVERSE ARRIVAL). Lets existing callers
    /// and test doubles stay sort-agnostic when the conventional Inbox
    /// order is all they need.
    func envelopes(folder: String, range: ClosedRange<UInt32>) async throws -> [Envelope] {
        try await envelopes(folder: folder, range: range, sort: .default)
    }

    /// Convenience overload — see `envelopes(folder:range:)` above.
    func topEnvelopes(
        folder: String,
        limit: UInt32,
        totalMessages: UInt32
    ) async throws -> [Envelope] {
        try await topEnvelopes(
            folder: folder,
            limit: limit,
            totalMessages: totalMessages,
            sort: .default
        )
    }

    /// Default implementation used by test doubles and any client that
    /// doesn't yet support IDLE. Returning an immediately-finished stream
    /// means the watcher yields one `.active` event and then sits in the
    /// reconnect backoff — cheap, correct, and no per-mock boilerplate.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Default implementation: only the API-backed client speaks the
    /// `/search_envelopes` contract today. `LiveImapClient` could grow a
    /// native translator (criteria list + `UID FETCH ENVELOPE`) but
    /// production never calls it, so the cheap default protects test
    /// doubles without forcing every conformer to ship a stub.
    func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult {
        throw CabalmailError.protocolError(
            "searchEnvelopes is not implemented by this ImapClient"
        )
    }

    /// Default implementation — same rationale as `searchEnvelopes`: the
    /// `/purge_messages` contract is API-only today and production never
    /// routes through `LiveImapClient`.
    func purge(folder: String, uids: [UInt32]) async throws {
        throw CabalmailError.protocolError(
            "purge is not implemented by this ImapClient"
        )
    }

    /// Default implementation — see `purge(folder:uids:)` above.
    func emptyTrash(folder: String) async throws {
        throw CabalmailError.protocolError(
            "emptyTrash is not implemented by this ImapClient"
        )
    }
}

/// One envelope returned by `searchEnvelopes(_:)` plus its source folder.
/// Cross-folder results carry the folder per row so operations on the
/// result set can route to the right mailbox; single-folder results set
/// `folder` to the query's folder so callers can treat the field as
/// always-present.
public struct SearchedEnvelope: Sendable, Hashable {
    public let envelope: Envelope
    public let folder: String

    public init(envelope: Envelope, folder: String) {
        self.envelope = envelope
        self.folder = folder
    }
}

/// Decoded `/search_envelopes` response. Mirrors the wire payload but
/// uses parsed `Envelope`s rather than the on-the-wire `ApiSearchEnvelope`
/// shape, so view models see the same envelope type as the rest of the
/// mailbox surface.
public struct SearchResult: Sendable, Hashable {
    public let envelopes: [SearchedEnvelope]
    public let totalEstimate: Int
    public let nextCursor: String?
    public let foldersSearched: [String]
    public let truncated: Bool

    public init(
        envelopes: [SearchedEnvelope],
        totalEstimate: Int,
        nextCursor: String?,
        foldersSearched: [String],
        truncated: Bool
    ) {
        self.envelopes = envelopes
        self.totalEstimate = totalEstimate
        self.nextCursor = nextCursor
        self.foldersSearched = foldersSearched
        self.truncated = truncated
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
