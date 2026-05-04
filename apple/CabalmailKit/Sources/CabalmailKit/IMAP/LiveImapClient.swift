import Foundation

/// Actor-based `ImapClient` implementation.
///
/// Split across two files: the core protocol conformance and helpers live
/// here; the IDLE surface lives in `LiveImapClient+Idle.swift`. The split
/// is mechanical — both halves are part of the same actor and can call
/// each other's `internal` members directly.
public actor LiveImapClient: ImapClient {
    private let factory: ImapConnectionFactory
    private let authService: AuthService
    private var connection: ImapConnection?
    var delimiter: String = "."
    private var selectedFolder: String?

    public init(factory: ImapConnectionFactory, authService: AuthService) {
        self.factory = factory
        self.authService = authService
    }

    // MARK: - Connection

    /// Opens and authenticates an IMAP session. Idempotent — a second call
    /// while a healthy connection exists is a no-op, so view models can
    /// call this before every folder/fetch without leaking sockets or
    /// re-logging-in.
    ///
    /// If the previous connection was dropped (explicit `disconnect()` or
    /// a transport error that nil-ed `connection`), this opens a fresh one
    /// and resets the `SELECTed` mailbox state so the next `select()` call
    /// actually issues the SELECT command against the new socket.
    public func connectAndAuthenticate() async throws {
        if connection != nil { return }
        let stream = try await factory.makeConnection()
        let conn = ImapConnection(stream: stream)
        _ = try await conn.readGreeting()

        let creds = try await authService.currentImapCredentials()
        // Quote username and password per RFC 3501 `astring` rules. Any
        // character that can't live in a quoted-string (roughly: literal
        // back-slash or double-quote) is fine here because Cognito usernames
        // don't include those.
        let quotedUser = quoteAstring(creds.username)
        let quotedPass = quoteAstring(creds.password)
        _ = try await conn.sendCommand("LOGIN \(quotedUser) \(quotedPass)")
        connection = conn
        // Fresh socket — no mailbox selected yet. Without this reset a
        // stale `selectedFolder` from a prior, torn-down session would
        // trick `select()` into skipping the SELECT command.
        selectedFolder = nil
    }

    public func disconnect() async {
        if let connection {
            _ = try? await connection.sendCommand("LOGOUT")
            await connection.close()
        }
        connection = nil
        selectedFolder = nil
    }

    /// Closes the cached connection without sending LOGOUT. The connection is
    /// assumed to be unreachable (dead socket after a network change), so we
    /// cancel it directly rather than trying to speak IMAP across it.
    public func invalidate() async {
        guard let stale = connection else { return }
        connection = nil
        selectedFolder = nil
        await stale.close()
    }

    // Used by the IDLE extension to build a second authenticated connection
    // without re-implementing the LOGIN handshake. Returns a fully-logged-in
    // `ImapConnection` whose lifetime the caller owns.
    func openAuthenticatedConnection() async throws -> ImapConnection {
        let stream = try await factory.makeConnection()
        let conn = ImapConnection(stream: stream)
        _ = try await conn.readGreeting()
        let creds = try await authService.currentImapCredentials()
        _ = try await conn.sendCommand(
            "LOGIN \(quoteAstring(creds.username)) \(quoteAstring(creds.password))"
        )
        return conn
    }

    // MARK: - Folders

    public func listFolders() async throws -> [Folder] {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            let listResponses = try await conn.sendCommand("LIST \"\" \"*\"")
            let lsubResponses = try await conn.sendCommand("LSUB \"\" \"*\"")

            var subscribed: Set<String> = []
            for response in lsubResponses {
                if case let .lsub(_, delimiter, mailbox) = response {
                    self.delimiter = delimiter.isEmpty ? self.delimiter : delimiter
                    subscribed.insert(mailbox)
                }
            }
            var folders: [Folder] = []
            for response in listResponses {
                if case let .list(attributes, delimiter, mailbox) = response {
                    self.delimiter = delimiter.isEmpty ? self.delimiter : delimiter
                    let path = self.toClientPath(mailbox)
                    folders.append(Folder(
                        path: path,
                        attributes: attributes,
                        isSubscribed: subscribed.contains(mailbox)
                    ))
                }
            }
            return folders
        }
    }

    public func createFolder(name: String, parent: String?) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            let fullClientPath: String
            if let parent, !parent.isEmpty {
                fullClientPath = "\(parent)/\(name)"
            } else {
                fullClientPath = name
            }
            _ = try await conn.sendCommand("CREATE \(self.quoteAstring(self.toServerPath(fullClientPath)))")
        }
    }

    public func deleteFolder(path: String) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            _ = try await conn.sendCommand("DELETE \(self.quoteAstring(self.toServerPath(path)))")
        }
    }

    public func subscribe(path: String) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            _ = try await conn.sendCommand("SUBSCRIBE \(self.quoteAstring(self.toServerPath(path)))")
        }
    }

    public func unsubscribe(path: String) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            _ = try await conn.sendCommand("UNSUBSCRIBE \(self.quoteAstring(self.toServerPath(path)))")
        }
    }

    public func status(path: String) async throws -> FolderStatus {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            let responses = try await conn.sendCommand(
                "STATUS \(self.quoteAstring(self.toServerPath(path))) (MESSAGES UNSEEN RECENT UIDVALIDITY UIDNEXT)"
            )
            for response in responses {
                if case let .status2(_, attrs) = response {
                    return FolderStatus(
                        messages: attrs["MESSAGES"].map(Int.init),
                        unseen: attrs["UNSEEN"].map(Int.init),
                        recent: attrs["RECENT"].map(Int.init),
                        uidValidity: attrs["UIDVALIDITY"].map { UInt32(truncatingIfNeeded: $0) },
                        uidNext: attrs["UIDNEXT"].map { UInt32(truncatingIfNeeded: $0) }
                    )
                }
            }
            return FolderStatus()
        }
    }

    // MARK: - Messages

    public func envelopes(folder: String, range: ClosedRange<UInt32>) async throws -> [Envelope] {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let spec = "\(range.lowerBound):\(range.upperBound)"
            let responses = try await conn.sendCommand(
                "UID FETCH \(spec) (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)"
            )
            return responses.compactMap { self.envelopeFromFetch($0) }
        }
    }

    public func topEnvelopes(
        folder: String,
        limit: UInt32,
        totalMessages: UInt32
    ) async throws -> [Envelope] {
        guard totalMessages > 0, limit > 0 else { return [] }
        return try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let start = totalMessages > limit ? totalMessages - limit + 1 : 1
            let responses = try await conn.sendCommand(
                "FETCH \(start):* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)"
            )
            return responses.compactMap { self.envelopeFromFetch($0) }
        }
    }

    public func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let responses = try await conn.sendCommand("UID FETCH \(uid) (UID FLAGS BODY.PEEK[])")
            for response in responses {
                if case let .fetch(_, attrs) = response, let body = attrs.body {
                    return RawMessage(uid: attrs.uid ?? uid, bytes: body, flags: attrs.flags ?? [])
                }
            }
            throw CabalmailError.protocolError("Server returned no BODY for UID \(uid)")
        }
    }

    public func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let responses = try await conn.sendCommand("UID FETCH \(uid) (BODY.PEEK[\(partId)])")
            for response in responses {
                if case let .fetch(_, attrs) = response, let body = attrs.body {
                    return body
                }
            }
            throw CabalmailError.protocolError("Server returned no part \(partId) for UID \(uid)")
        }
    }

    public func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let uidList = uids.map(String.init).joined(separator: ",")
            let flagList = flags.map { $0.wireValue }.joined(separator: " ")
            _ = try await conn.sendCommand("UID STORE \(uidList) \(operation.wireValue) (\(flagList))")
        }
    }

    public func move(folder: String, uids: [UInt32], destination: String) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let uidList = uids.map(String.init).joined(separator: ",")
            let dest = self.quoteAstring(self.toServerPath(destination))
            do {
                _ = try await conn.sendCommand("UID MOVE \(uidList) \(dest)")
                return
            } catch CabalmailError.imapCommandFailed {
                // Fallback for servers without MOVE (RFC 6851) — COPY + STORE + EXPUNGE.
                _ = try await conn.sendCommand("UID COPY \(uidList) \(dest)")
                _ = try await conn.sendCommand("UID STORE \(uidList) +FLAGS (\\Deleted)")
                _ = try await conn.sendCommand("UID EXPUNGE \(uidList)")
            }
        }
    }

    public func search(folder: String, query: String) async throws -> [UInt32] {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            try await self.select(folder: folder, on: conn)
            let responses = try await conn.sendCommand("UID SEARCH \(query)")
            for response in responses {
                if case let .search(ids) = response {
                    return ids
                }
            }
            return []
        }
    }

    public func append(folder: String, message: Data, flags: Set<Flag>) async throws {
        try await withTransportRetry {
            let conn = try self.requireConnection()
            let flagList = flags.isEmpty ? "" : " (\(flags.map { $0.wireValue }.joined(separator: " ")))"
            let command = "APPEND \(self.quoteAstring(self.toServerPath(folder)))\(flagList) {\(message.count)}"
            _ = try await conn.sendCommand(command, literal: message)
        }
    }

    // MARK: - Transport retry

    /// Runs `operation`, and on a `.transport` / `.network` failure from a
    /// cached connection, invalidates + reconnects + runs it once more.
    ///
    /// Also retries once on a `"No mailbox selected"` server response: the
    /// optimistic select-skip in `select(...)` keys off our cached
    /// `selectedFolder`, but the server can implicitly drop us out of
    /// SELECTED state in ways the client doesn't observe (a parallel
    /// failed SELECT, a folder deleted/renamed by another client, etc.).
    /// Resetting the cache and re-running `operation` re-issues SELECT and
    /// recovers without bothering the user.
    ///
    /// The retry fires at most once. If the reconnect itself fails, or the
    /// second attempt fails for any reason, the error surfaces unchanged —
    /// no endless reconnect loops on a genuinely broken network. Other
    /// server errors (auth, protocol, command rejections) bypass the retry.
    ///
    /// The closure is actor-isolated (no `@Sendable`), so it can reference
    /// `self` and mutate actor state freely.
    private func withTransportRetry<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as CabalmailError where Self.isRecoverableTransportError(error) {
            await invalidate()
            try await connectAndAuthenticate()
            return try await operation()
        } catch let error as CabalmailError where Self.isNoMailboxSelected(error) {
            invalidateSelectedFolder()
            return try await operation()
        }
    }

    private static func isRecoverableTransportError(_ error: CabalmailError) -> Bool {
        switch error {
        case .transport, .network: return true
        default: return false
        }
    }

    /// Detects the IMAP "No mailbox selected" response. Servers vary in
    /// wording (Dovecot: `"No mailbox selected."`; some older servers:
    /// `"No mailbox is selected."`), so we match case-insensitively on the
    /// stable substring.
    private static func isNoMailboxSelected(_ error: CabalmailError) -> Bool {
        guard case let .imapCommandFailed(_, detail) = error else { return false }
        return detail.range(of: "no mailbox", options: .caseInsensitive) != nil
            && detail.range(of: "selected", options: .caseInsensitive) != nil
    }
}

// MARK: - Internals

// Module-internal rather than `private` so the IDLE extension in
// `LiveImapClient+Idle.swift` can reach `quoteAstring` and `toServerPath`
// without re-implementing them. Not exposed publicly.
extension LiveImapClient {
    func requireConnection() throws -> ImapConnection {
        guard let connection else {
            throw CabalmailError.notSignedIn
        }
        return connection
    }

    func select(folder: String, on conn: ImapConnection) async throws {
        if selectedFolder == folder { return }
        do {
            _ = try await conn.sendCommand("SELECT \(quoteAstring(toServerPath(folder)))")
        } catch {
            // RFC 3501 §6.3.1: a failed SELECT puts the connection in
            // AUTHENTICATED state — the server's previously-selected mailbox
            // is no longer selected. Drop our cache so the next select()
            // actually re-SELECTs instead of optimistically skipping based
            // on a stale "we're still in <folder>" assumption (which is the
            // shape of the "No mailbox selected" error from issue #356).
            selectedFolder = nil
            throw error
        }
        selectedFolder = folder
    }

    /// Forces the actor's cached `selectedFolder` to nil so the next
    /// `select(...)` call always re-issues SELECT. Used by the
    /// "No mailbox selected" recovery path when a server has unselected the
    /// mailbox unexpectedly (e.g., after another client deleted/renamed it,
    /// or a transient server-side issue).
    func invalidateSelectedFolder() {
        selectedFolder = nil
    }

    func toServerPath(_ clientPath: String) -> String {
        if delimiter == "/" { return clientPath }
        return clientPath.replacingOccurrences(of: "/", with: delimiter)
    }

    func toClientPath(_ serverPath: String) -> String {
        if delimiter == "/" { return serverPath }
        return serverPath.replacingOccurrences(of: delimiter, with: "/")
    }

    nonisolated func quoteAstring(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated func envelopeFromFetch(_ response: ImapResponse) -> Envelope? {
        guard case let .fetch(_, attrs) = response else { return nil }
        guard let uid = attrs.uid else { return nil }
        let envelope = attrs.envelope ?? ImapEnvelopeFields()
        return Envelope(
            uid: uid,
            messageId: envelope.messageId,
            date: envelope.date,
            subject: envelope.subject,
            from: envelope.from,
            sender: envelope.sender,
            replyTo: envelope.replyTo,
            to: envelope.to,
            cc: envelope.cc,
            bcc: envelope.bcc,
            inReplyTo: envelope.inReplyTo,
            flags: attrs.flags ?? [],
            internalDate: attrs.internalDate,
            size: attrs.rfc822Size,
            hasAttachments: attrs.hasAttachments ?? false
        )
    }
}
