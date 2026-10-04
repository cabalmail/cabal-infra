import Foundation

/// High-level mailbox operations used by the rest of the Apple client.
///
/// The production implementation is `ApiBackedImapClient`, which maps each
/// call onto a Cabalmail Lambda endpoint (issue #371); nothing in the app
/// speaks IMAP directly.
///
/// Folder paths in this API use `/` as the delimiter regardless of the
/// server's native separator (Dovecot's is `.`). The Lambdas perform the
/// translation with `.replace("/", ".")`.
public protocol ImapClient: Sendable {
    func listFolders() async throws -> [Folder]
    func createFolder(name: String, parent: String?) async throws
    func deleteFolder(path: String) async throws
    func subscribe(path: String) async throws
    func unsubscribe(path: String) async throws
    /// STATUS for a folder. Pass `flagged: true` to also get a flagged count
    /// (an extra SEARCH FLAGGED); the cheap STATUS-only `status(path:)`
    /// convenience leaves `FolderStatus.flagged` nil for badge/idle polls.
    func status(path: String, flagged: Bool) async throws -> FolderStatus

    /// Fetches a positional page: the `limit` envelopes starting at `offset`
    /// in the sorted result (offset 0 is the newest page under the default
    /// reverse sort). Unlike the UID-range variant this respects any sort
    /// field -- UID order is not sort order under From/Subject -- and never
    /// dead-ends on sparse folders, since the caller stops when the loaded
    /// count reaches the folder's STATUS message count. The API-backed client
    /// overrides this with `/list_messages?offset=&limit=`; the default throws
    /// so test doubles needn't implement it.
    func envelopes(
        folder: String,
        offset: UInt32,
        limit: UInt32,
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
    func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws

    /// Moves messages to `destination`. When `markSeen` is true the server
    /// adds `\Seen` before the move, folding archive's "mark read, then file"
    /// into a single round trip (see `/move_messages`' `mark_seen`). The
    /// three-argument convenience below forwards with `markSeen: false` so
    /// plain "file this for later" moves stay unread.
    func move(folder: String, uids: [UInt32], destination: String, markSeen: Bool) async throws

    /// Permanently deletes (expunges) the given messages. The backing
    /// `/purge_messages` Lambda only accepts trash folders, so callers
    /// should gate this on the folder being Trash. The default extension
    /// throws `protocolError`; the API-backed implementation overrides it
    /// (same pattern as `searchEnvelopes`).
    func purge(folder: String, uids: [UInt32]) async throws

    /// Permanently deletes every message in a trash folder (backed by
    /// `/empty_trash`, same trash-only restriction and default).
    func emptyTrash(folder: String) async throws

    /// Marks every unseen message in `folder` as `\Seen` in one server-side
    /// pass (backed by `/mark_folder_read`; same API-only default as
    /// `purge`). Returns how many messages were flipped.
    func markFolderRead(folder: String) async throws -> Int

    /// Structured search across one folder (`query.folder` set) or every
    /// subscribed folder (`query.folder == nil`). Returns envelopes with
    /// their source folder attached, plus the pagination cursor required
    /// to fetch the next page. The wire path is one round trip — no
    /// post-fetch UID range expansion at the call site.
    ///
    /// The default extension throws `protocolError`; the API-backed
    /// implementation overrides it.
    func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult

    /// Opens a change stream for `folder` and yields `IdleEvent`s until
    /// cancelled. The name is historical (IMAP IDLE): the API-backed client
    /// polls folder status and synthesizes the events (see
    /// `ApiBackedImapClient.idle(folder:)`). Implementations without a
    /// server (unit-test mocks, in-memory fakes) can return an empty
    /// stream — `MailboxWatcher` treats an immediately-finished stream as a
    /// clean exit and backs off, which is the right behavior for those
    /// transports.
    ///
    /// `MessageListViewModel` runs a `MailboxWatcher` over the resulting
    /// stream so a reported EXISTS / EXPUNGE / FETCH triggers an envelope
    /// refresh. The watcher itself holds the reconnect / backoff policy.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error>
}

public extension ImapClient {
    /// Convenience overload — a plain move that leaves read state alone.
    /// "File this for later" keeps unread; only archive/dispose passes
    /// `markSeen: true`.
    func move(folder: String, uids: [UInt32], destination: String) async throws {
        try await move(folder: folder, uids: uids, destination: destination, markSeen: false)
    }

    /// Convenience overload — the cheap STATUS-only call (no flagged count).
    /// Existing callers (the inbox badge poller, idle, the sidebar count
    /// refresh) keep working unchanged; only the message-list refresh, which
    /// drives the filter-pill counts, asks for `flagged: true`.
    func status(path: String) async throws -> FolderStatus {
        try await status(path: path, flagged: false)
    }

    /// Convenience overload — delegates to the sorted variant with
    /// `SortCriterion.default` (REVERSE ARRIVAL).
    func envelopes(folder: String, offset: UInt32, limit: UInt32) async throws -> [Envelope] {
        try await envelopes(folder: folder, offset: offset, limit: limit, sort: .default)
    }

    /// Default: positional pagination is an API-backed contract (offset/limit
    /// on `/list_messages`). Test doubles inherit this throw.
    func envelopes(
        folder: String,
        offset: UInt32,
        limit: UInt32,
        sort: SortCriterion
    ) async throws -> [Envelope] {
        throw CabalmailError.protocolError(
            "envelopes(offset:limit:) is not implemented by this ImapClient"
        )
    }

    /// Convenience overload — delegates to the sorted variant with
    /// `SortCriterion.default`.
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

    /// Default implementation for test doubles and in-memory fakes, which
    /// have no server to poll. Returning an immediately-finished stream
    /// means the watcher yields one `.active` event and then sits in the
    /// reconnect backoff — cheap, correct, and no per-mock boilerplate.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// Default implementation: only the API-backed client speaks the
    /// `/search_envelopes` contract, so the cheap default protects test
    /// doubles without forcing every conformer to ship a stub.
    func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult {
        throw CabalmailError.protocolError(
            "searchEnvelopes is not implemented by this ImapClient"
        )
    }

    /// Fetches a search result set in bounded pages instead of one large
    /// request. Issues `searchEnvelopes(_:)` with `limit == pageSize`, then
    /// walks `nextCursor` until the accumulated count reaches `maxResults`
    /// or the server runs dry. Every round trip asks for at most `pageSize`
    /// envelopes, so a wide-but-sparse match set never produces a single
    /// oversized request -- Layer 3.2 of
    /// `docs/0.10.x/large-mailbox-hardening-plan.md`.
    ///
    /// `totalEstimate` and `foldersSearched` come from the first page (the
    /// Lambda reports the same values on every page of one query).
    /// `truncated` is the union of every page's flag -- i.e. the server's
    /// "match count is a lower bound" signal, unchanged. The returned
    /// `nextCursor` is the cursor the next unfetched page would use, or nil
    /// once the set is exhausted; when it is non-nil the caller has fetched
    /// fewer than `totalEstimate` rows and its banner reflects the gap.
    func searchEnvelopesChunked(
        _ query: SearchQuery,
        pageSize: Int,
        maxResults: Int
    ) async throws -> SearchResult {
        // Defensive: a non-positive page size would request limit 0 (which
        // the Lambda clamps back up to 1) and spin. Clamp to at least one.
        let pageSize = max(1, pageSize)
        var collected: [SearchedEnvelope] = []
        var cursor: String? = query.cursor
        var totalEstimate = 0
        var foldersSearched: [String] = []
        var truncated = false
        var isFirstPage = true
        while collected.count < maxResults {
            let pageLimit = min(pageSize, maxResults - collected.count)
            let page = try await searchEnvelopes(query.page(limit: pageLimit, cursor: cursor))
            if isFirstPage {
                totalEstimate = page.totalEstimate
                foldersSearched = page.foldersSearched
                isFirstPage = false
            }
            collected.append(contentsOf: page.envelopes)
            truncated = truncated || page.truncated
            cursor = page.nextCursor
            // Exhausted the match set, or a page came back empty while still
            // handing back a cursor (would otherwise loop forever).
            if cursor == nil || page.envelopes.isEmpty { break }
        }
        return SearchResult(
            envelopes: collected,
            totalEstimate: totalEstimate,
            nextCursor: cursor,
            foldersSearched: foldersSearched,
            truncated: truncated
        )
    }

    /// Default implementation — same rationale as `searchEnvelopes`: the
    /// `/purge_messages` contract is API-only.
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

    /// Default implementation — see `purge(folder:uids:)` above.
    func markFolderRead(folder: String) async throws -> Int {
        throw CabalmailError.protocolError(
            "markFolderRead is not implemented by this ImapClient"
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

/// A mailbox change reported by `ImapClient.idle(folder:)`. The API-backed
/// client polls folder status and synthesizes these (see
/// `ApiBackedImapClient.idle(folder:)`).
public struct IdleEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case exists(UInt32)
        case expunge(UInt32)
        case fetch(UInt32)
    }
    public let kind: Kind

    /// Public so an `ImapClient` conformer outside the Kit (a test double)
    /// can produce events too.
    public init(kind: Kind) {
        self.kind = kind
    }
}
