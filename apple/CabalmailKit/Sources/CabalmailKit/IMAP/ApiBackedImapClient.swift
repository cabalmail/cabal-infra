import Foundation

/// `ImapClient` implementation that talks to the Cabalmail Lambda API
/// instead of speaking IMAP directly.
///
/// Issue #371: the hand-rolled IMAP stack proved unreliable across
/// network transitions, sleep/wake, and provider quirks. The React client
/// has been running off the same Lambda surface since 0.2.0 with no such
/// trouble, so we route the Apple client through it as well. This actor
/// adapts the React-shaped API onto the existing `ImapClient` protocol so
/// view-models keep compiling unchanged.
///
/// Trade-offs vs. native IMAP:
///   * No IDLE — `idle(folder:)` polls `/folder_status` every
///     `pollInterval` seconds and yields `.exists(uidNext)` whenever the
///     folder's `UIDNEXT` advances (or `.expunge(0)` when the message count
///     drops). The first poll runs before the stream is returned, so an
///     unreachable API fails the open the way a refused IMAP connection
///     would. `MailboxWatcher` applies the reconnect backoff and
///     `MessageListViewModel` coalesces bursts, so callers see the same
///     observable contract.
///   * SEARCH is mediated by the `/search_envelopes` Lambda — clients
///     pass a structured `SearchQuery` and receive envelopes plus a
///     pagination cursor in a single round trip. The raw-IMAP-syntax
///     `/search` Lambda was retired in 0.9.x (Phase 6 of
///     `docs/0.9.x/imap-search-plan.md`).
///   * No raw APPEND — `/send` handles the Outbox + Sent shuffle
///     server-side and `/save_draft` owns the Drafts-folder lifecycle
///     (save / replace / discard with UIDPLUS coordinates), so no caller
///     needs a byte-level APPEND.
///   * No single-part fetch — there is no mapping from RFC 3501 part IDs
///     to the Lambda's attachment index, so callers fetch the full body
///     with `fetchBody` and parse MIME client-side.
///   * Envelope addresses arrive in RFC 5322 mailbox form — the Lambda
///     emits `"Display Name" <mailbox@host>` when an addr-name is set
///     and bare `mailbox@host` otherwise. `parseAddress` splits the two
///     shapes apart so `EmailAddress.name` is populated when available.
public actor ApiBackedImapClient: ImapClient {
    private let api: ApiClient
    private let host: String
    private let pollInterval: TimeInterval

    public init(api: ApiClient, host: String, pollInterval: TimeInterval = 30) {
        self.api = api
        self.host = host
        self.pollInterval = pollInterval
    }

    // MARK: - Folders

    public func listFolders() async throws -> [Folder] {
        let list = try await api.listFolders(host: host)
        let subscribed = Set(list.subFolders)
        // The Lambda already returns folder paths with `.` → `/`, sorted.
        return list.folders.map { path in
            Folder(path: path, attributes: [], isSubscribed: subscribed.contains(path))
        }
    }

    public func createFolder(name: String, parent: String?) async throws {
        try await api.createFolder(host: host, parent: parent ?? "", name: name)
    }

    public func deleteFolder(path: String) async throws {
        try await api.deleteFolder(host: host, name: path)
    }

    public func subscribe(path: String) async throws {
        try await api.subscribeFolder(host: host, folder: path)
    }

    public func unsubscribe(path: String) async throws {
        try await api.unsubscribeFolder(host: host, folder: path)
    }

    public func status(path: String, flagged: Bool) async throws -> FolderStatus {
        let raw = try await api.folderStatus(host: host, folder: path, flagged: flagged)
        return FolderStatus(
            messages: raw.messages,
            unseen: raw.unseen,
            flagged: raw.flagged,
            recent: nil,
            uidValidity: raw.uidValidity,
            uidNext: raw.uidNext
        )
    }

    // MARK: - Bodies and parts

    public func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage {
        // `/fetch_message` returns a presigned S3 URL for the raw RFC 822;
        // we follow it and surface the bytes alongside the UID. Flags are
        // unavailable from this endpoint, so the returned set is empty —
        // callers that need flags should consult the prior envelope fetch.
        let body = try await api.fetchMessage(host: host, folder: folder, id: uid, markSeen: false)
        guard let raw = body.messageRaw, let url = URL(string: raw) else {
            throw CabalmailError.decoding("fetch_message returned no presigned URL")
        }
        let data = try await api.fetchPresignedData(url: url)
        return RawMessage(uid: uid, bytes: data, flags: [])
    }

    // MARK: - Flags and moves

    public func setFlags(
        folder: String,
        uids: [UInt32],
        flags: Set<Flag>,
        operation: FlagOperation
    ) async throws {
        // The Lambda's `/set_flag` accepts a single flag and an op of
        // "set" / "unset" — see `lambda/api/set_flag/function.py`. Map the
        // protocol's set-of-flags shape onto one call per flag. A multi-flag
        // toggle (e.g. "mark read + unflag") is otherwise N serial round
        // trips, each carrying the full UID set, so issue them concurrently
        // (Layer 3.5 of `docs/0.10.x/large-mailbox-hardening-plan.md`).
        let wireOp: String
        switch operation {
        case .add:     wireOp = "set"
        case .remove:  wireOp = "unset"
        case .replace:
            // The API has no atomic STORE FLAGS — best-effort emulate by
            // adding the requested flags. Replace semantics are only used
            // for niche admin paths today.
            wireOp = "set"
        }
        // Snapshot actor state before fanning out; the child tasks run
        // outside this actor's isolation, so they must not touch `self`.
        // Each per-flag leg walks the UID list in `bulkChunkSize` chunks
        // (see `ApiBackedImapClient+Bulk.swift`) and reports its
        // succeeded/failed split; the merge below throws
        // `bulkPartialFailure` when any UID missed any flag.
        let api = self.api
        let host = self.host
        let sortOrder = defaultSortOrder
        let sortField = defaultSortField
        let outcomes = await withTaskGroup(of: BulkChunkOutcome.self) { group in
            for flag in flags {
                group.addTask {
                    await Self.runChunked(uids: uids) { chunk in
                        try await api.setFlag(SetFlagRequest(
                            host: host,
                            folder: folder,
                            ids: chunk,
                            flag: flag.wireValue,
                            operation: wireOp,
                            sortOrder: sortOrder,
                            sortField: sortField
                        ))
                    }
                }
            }
            var collected: [BulkChunkOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        try Self.throwIfIncomplete(outcomes)
    }

    public func move(folder: String, uids: [UInt32], destination: String, markSeen: Bool) async throws {
        let api = self.api
        let host = self.host
        let sortOrder = defaultSortOrder
        let sortField = defaultSortField
        let outcome = await Self.runChunked(uids: uids) { chunk in
            try await api.moveMessages(MoveMessagesRequest(
                host: host,
                source: folder,
                destination: destination,
                ids: chunk,
                markSeen: markSeen,
                sortOrder: sortOrder,
                sortField: sortField
            ))
        }
        try Self.throwIfIncomplete([outcome])
    }

    // MARK: - Search

    // `searchEnvelopes(_:)` lives in an extension below so the primary
    // type body stays under SwiftLint's 250-line cap.

    // MARK: - IDLE (polling fallback)

    public func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        let api = self.api
        let host = self.host
        let interval = self.pollInterval
        // The first poll runs here, before the stream exists, so an
        // unreachable API fails the open itself. `MailboxWatcher` resets its
        // reconnect backoff whenever an open succeeds; with this poll inside
        // the stream every open succeeded, and a list left open offline
        // retried every 2 s instead of backing off (#1797). A planned
        // maintenance window still opens: the stream polls quietly until the
        // roll is over.
        let baseline: ApiFolderStatus?
        do {
            baseline = try await api.folderStatus(host: host, folder: folder)
        } catch let error as CabalmailError {
            guard case .maintenance = error else { throw error }
            baseline = nil
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastUidNext = baseline?.uidNext
                var lastMessages = baseline?.messages
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    do {
                        let status = try await api.folderStatus(host: host, folder: folder)
                        if let uidNext = status.uidNext, lastUidNext != nil, uidNext > (lastUidNext ?? 0) {
                            continuation.yield(IdleEvent(kind: .exists(uidNext)))
                        }
                        if let messages = status.messages, let prior = lastMessages, messages < prior {
                            continuation.yield(IdleEvent(kind: .expunge(0)))
                        }
                        lastUidNext = status.uidNext
                        lastMessages = status.messages
                    } catch let error as CabalmailError {
                        if case .maintenance = error {
                            // Planned IMAP roll: keep polling quietly until it
                            // returns rather than tearing down the stream and
                            // churning MailboxWatcher reconnects for a window
                            // that clears itself in a minute or two.
                        } else {
                            // Any other failure ends the stream, and
                            // MailboxWatcher reopens it after its backoff. A
                            // failure that persists (offline, an expired
                            // session) then fails the reopen's first poll
                            // above, so the backoff doubles toward its cap
                            // rather than the watcher stopping.
                            continuation.finish(throwing: error)
                            return
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conversion helpers

    private var defaultSortOrder: String { "REVERSE " }
    private var defaultSortField: String { "ARRIVAL" }

    /// Builds an `Envelope` from the Lambda payload. `internalDate` and
    /// `size` are approximated/omitted — the Lambda doesn't surface them
    /// and the cache keys on UID + UIDVALIDITY. The threading identity
    /// (`messageId` / `inReplyTo` / `references`) is populated when the
    /// payload carries it (Lambdas since the 0.10.x draft-sync work);
    /// `ReplyBuilder` threads replies from these fields.
    static func makeEnvelope(_ raw: ApiEnvelope) -> Envelope {
        let date = parseLambdaDate(raw.date)
        let flags = Set(raw.flags.map { Flag(wireValue: $0) })
        return Envelope(
            uid: raw.id,
            messageId: raw.messageId?.first,
            date: date,
            subject: raw.subject,
            from: raw.from.compactMap(parseAddress),
            sender: [],
            replyTo: [],
            to: raw.to.compactMap(parseAddress),
            cc: raw.cc.compactMap(parseAddress),
            bcc: (raw.bcc ?? []).compactMap(parseAddress),
            inReplyTo: raw.inReplyTo?.first,
            references: raw.references ?? [],
            flags: flags,
            internalDate: date,
            size: nil,
            hasAttachments: raw.structure?.hasAttachments ?? false,
            isImportant: Self.isImportant(priority: raw.priority),
            authResults: raw.authResults
        )
    }

    /// Mirrors React (`Envelope.jsx`): the Lambda emits `priority-1`
    /// through `priority-5` tokens; 1 and 2 mean "high."
    static func isImportant(priority: [String]?) -> Bool {
        priority?.contains { $0 == "priority-1" || $0 == "priority-2" } ?? false
    }

    /// Parses an address from the Lambda's wire format.
    ///
    /// `/list_envelopes` emits each address in RFC 5322 mailbox form:
    /// `"Display Name" <mailbox@host>` when an addr-name is set, or bare
    /// `mailbox@host` when it isn't. Display-name quotes are stripped so
    /// the parsed `name` matches the React client's `extractName`
    /// presentation. The sentinel `undisclosed-recipients` (which the
    /// Lambda emits when an address fails to decode) becomes a placeholder
    /// `EmailAddress`.
    static func parseAddress(_ raw: String) -> EmailAddress? {
        if raw == "undisclosed-recipients" {
            return EmailAddress(name: nil, mailbox: "undisclosed-recipients", host: "")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"),
           open < close {
            let inside = String(trimmed[trimmed.index(after: open)..<close])
            let namePart = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            let name = stripWrappingQuotes(namePart)
            let (mailbox, host) = splitMailboxHost(inside)
            return EmailAddress(name: name.isEmpty ? nil : name, mailbox: mailbox, host: host)
        }
        let (mailbox, host) = splitMailboxHost(trimmed)
        return EmailAddress(name: nil, mailbox: mailbox, host: host)
    }

    private static func splitMailboxHost(_ value: String) -> (String, String) {
        guard let atIndex = value.lastIndex(of: "@") else { return (value, "") }
        return (String(value[..<atIndex]), String(value[value.index(after: atIndex)...]))
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Parses the Lambda's stringified date format. `imapclient` returns a
    /// timezone-aware `datetime` and the Lambda calls `str()` on it, which
    /// yields `"YYYY-MM-DD HH:MM:SS+00:00"`. A nil envelope date emits the
    /// literal string `"None"`.
    static func parseLambdaDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "None" else { return nil }
        let formatters: [DateFormatter] = [
            Self.makeFormatter("yyyy-MM-dd HH:mm:ssXXXXX"),
            Self.makeFormatter("yyyy-MM-dd HH:mm:ssZ"),
            Self.makeFormatter("yyyy-MM-dd HH:mm:ss"),
        ]
        for formatter in formatters {
            if let date = formatter.date(from: raw) { return date }
        }
        // Last-ditch ISO 8601 attempt — covers Lambda variants that emit
        // `2024-01-15T10:30:45Z` instead of the space-separated form.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Purge (extension)

// Permanent-deletion overrides for the trash-only Lambda endpoints. In an
// extension for the same reason as search below: the primary actor body
// sits near SwiftLint's 250-line cap.
extension ApiBackedImapClient {
    public func purge(folder: String, uids: [UInt32]) async throws {
        try await api.purgeMessages(host: host, folder: folder, ids: uids)
    }

    public func emptyTrash(folder: String) async throws {
        try await api.emptyTrash(host: host, folder: folder)
    }

    public func markFolderRead(folder: String) async throws -> Int {
        try await api.markFolderRead(host: host, folder: folder)
    }
}

// MARK: - Search (extension)

// `searchEnvelopes(_:)` lives in its own extension so the primary actor
// body stays under SwiftLint's 250-line cap; same-module extension, all
// `internal` helpers from the type are reachable.
extension ApiBackedImapClient {
    public func searchEnvelopes(_ query: SearchQuery) async throws -> SearchResult {
        let raw = try await api.searchEnvelopes(host: host, query: query)
        let envelopes = raw.envelopes.map { wire -> SearchedEnvelope in
            let inner = ApiEnvelope(
                id: wire.id,
                date: wire.date,
                subject: wire.subject,
                from: wire.from,
                to: wire.to,
                cc: wire.cc,
                bcc: wire.bcc,
                flags: wire.flags,
                structure: wire.structure,
                priority: wire.priority,
                messageId: wire.messageId,
                inReplyTo: wire.inReplyTo,
                references: wire.references,
                authResults: wire.authResults
            )
            return SearchedEnvelope(envelope: Self.makeEnvelope(inner), folder: wire.folder)
        }
        return SearchResult(
            envelopes: envelopes,
            totalEstimate: raw.totalEstimate,
            nextCursor: raw.nextCursor,
            foldersSearched: raw.foldersSearched,
            truncated: raw.truncated
        )
    }
}

// MARK: - Envelopes
// In an extension (same file, so it still reaches the actor's private
// `api`/`host`) to keep the main actor body under SwiftLint's type-body cap.
extension ApiBackedImapClient {
    public func envelopes(
        folder: String,
        offset: UInt32,
        limit: UInt32,
        sort: SortCriterion
    ) async throws -> [Envelope] {
        // Ask the Lambda for just this page of the sorted UID list, then fetch
        // its envelopes. Trust the server slice (no client-side prefix): at a
        // non-zero offset a defensive prefix would hand back the wrong window
        // if the slice ever arrived larger than requested.
        let ids = try await api.listMessageIds(
            host: host,
            folder: folder,
            sortOrder: sort.direction.wireOrder,
            sortField: sort.field.wireField,
            page: MessageIdPage(offset: offset, limit: limit)
        )
        guard !ids.isEmpty else { return [] }
        let raw = try await api.listEnvelopes(host: host, folder: folder, ids: ids)
        return raw.map { Self.makeEnvelope($0) }
    }

    public func topEnvelopes(
        folder: String,
        limit: UInt32,
        totalMessages: UInt32,
        sort: SortCriterion
    ) async throws -> [Envelope] {
        if totalMessages == 0 { return [] }
        let ids = try await api.listMessageIds(
            host: host,
            folder: folder,
            sortOrder: sort.direction.wireOrder,
            sortField: sort.field.wireField,
            page: MessageIdPage(offset: 0, limit: limit)
        )
        // Offset 0 is the top of the sorted list, so a defensive prefix is
        // always correct -- it also shields against an older Lambda that
        // predates pagination and ignores the params, returning the full list.
        let head = Array(ids.prefix(Int(limit)))
        guard !head.isEmpty else { return [] }
        let raw = try await api.listEnvelopes(host: host, folder: folder, ids: head)
        return raw.map { Self.makeEnvelope($0) }
    }
}
