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

/// Actor-based `ImapClient` implementation.
public actor LiveImapClient: ImapClient {
    private let factory: ImapConnectionFactory
    private let authService: AuthService
    private var connection: ImapConnection?
    private var delimiter: String = "."
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

    // MARK: - Folders

    public func listFolders() async throws -> [Folder] {
        let conn = try requireConnection()
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
                let path = toClientPath(mailbox)
                folders.append(Folder(
                    path: path,
                    attributes: attributes,
                    isSubscribed: subscribed.contains(mailbox)
                ))
            }
        }
        return folders
    }

    public func createFolder(name: String, parent: String?) async throws {
        let conn = try requireConnection()
        let fullClientPath: String
        if let parent, !parent.isEmpty {
            fullClientPath = "\(parent)/\(name)"
        } else {
            fullClientPath = name
        }
        _ = try await conn.sendCommand("CREATE \(quoteAstring(toServerPath(fullClientPath)))")
    }

    public func deleteFolder(path: String) async throws {
        let conn = try requireConnection()
        _ = try await conn.sendCommand("DELETE \(quoteAstring(toServerPath(path)))")
    }

    public func subscribe(path: String) async throws {
        let conn = try requireConnection()
        _ = try await conn.sendCommand("SUBSCRIBE \(quoteAstring(toServerPath(path)))")
    }

    public func unsubscribe(path: String) async throws {
        let conn = try requireConnection()
        _ = try await conn.sendCommand("UNSUBSCRIBE \(quoteAstring(toServerPath(path)))")
    }

    public func status(path: String) async throws -> FolderStatus {
        let conn = try requireConnection()
        let responses = try await conn.sendCommand(
            "STATUS \(quoteAstring(toServerPath(path))) (MESSAGES UNSEEN RECENT UIDVALIDITY UIDNEXT)"
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

    // MARK: - Messages

    public func envelopes(folder: String, range: ClosedRange<UInt32>) async throws -> [Envelope] {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let spec = "\(range.lowerBound):\(range.upperBound)"
        let responses = try await conn.sendCommand(
            "UID FETCH \(spec) (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)"
        )
        return responses.compactMap { envelopeFromFetch($0) }
    }

    public func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let responses = try await conn.sendCommand("UID FETCH \(uid) (UID FLAGS BODY.PEEK[])")
        for response in responses {
            if case let .fetch(_, attrs) = response, let body = attrs.body {
                return RawMessage(uid: attrs.uid ?? uid, bytes: body, flags: attrs.flags ?? [])
            }
        }
        throw CabalmailError.protocolError("Server returned no BODY for UID \(uid)")
    }

    public func fetchPart(folder: String, uid: UInt32, partId: String) async throws -> Data {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let responses = try await conn.sendCommand("UID FETCH \(uid) (BODY.PEEK[\(partId)])")
        for response in responses {
            if case let .fetch(_, attrs) = response, let body = attrs.body {
                return body
            }
        }
        throw CabalmailError.protocolError("Server returned no part \(partId) for UID \(uid)")
    }

    public func setFlags(folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation) async throws {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let uidList = uids.map(String.init).joined(separator: ",")
        let flagList = flags.map { $0.wireValue }.joined(separator: " ")
        _ = try await conn.sendCommand("UID STORE \(uidList) \(operation.wireValue) (\(flagList))")
    }

    public func move(folder: String, uids: [UInt32], destination: String) async throws {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let uidList = uids.map(String.init).joined(separator: ",")
        do {
            _ = try await conn.sendCommand("UID MOVE \(uidList) \(quoteAstring(toServerPath(destination)))")
            return
        } catch CabalmailError.imapCommandFailed {
            // Fallback for servers without MOVE (RFC 6851) — COPY + STORE + EXPUNGE.
            _ = try await conn.sendCommand("UID COPY \(uidList) \(quoteAstring(toServerPath(destination)))")
            _ = try await conn.sendCommand("UID STORE \(uidList) +FLAGS (\\Deleted)")
            _ = try await conn.sendCommand("UID EXPUNGE \(uidList)")
        }
    }

    public func search(folder: String, query: String) async throws -> [UInt32] {
        let conn = try requireConnection()
        try await select(folder: folder, on: conn)
        let responses = try await conn.sendCommand("UID SEARCH \(query)")
        for response in responses {
            if case let .search(ids) = response {
                return ids
            }
        }
        return []
    }

    public func append(folder: String, message: Data, flags: Set<Flag>) async throws {
        let conn = try requireConnection()
        let flagList = flags.isEmpty ? "" : " (\(flags.map { $0.wireValue }.joined(separator: " ")))"
        let command = "APPEND \(quoteAstring(toServerPath(folder)))\(flagList) {\(message.count)}"
        _ = try await conn.sendCommand(command, literal: message)
    }

}

// MARK: - IDLE

public extension LiveImapClient {
    /// Opens a dedicated IMAP connection, SELECTs the folder, issues IDLE,
    /// and yields untagged `EXISTS` / `EXPUNGE` / `FETCH` events until the
    /// stream is terminated. Terminating the stream sends `DONE` and closes
    /// the connection.
    func idle(folder: String) async throws -> AsyncThrowingStream<IdleEvent, Error> {
        let idleConnection = try await startIdleConnection(folder: folder)
        return makeIdleStream(idleConnection: idleConnection)
    }

    private func startIdleConnection(folder: String) async throws -> ImapConnection {
        let stream = try await factory.makeConnection()
        let idleConnection = ImapConnection(stream: stream)
        _ = try await idleConnection.readGreeting()
        let creds = try await authService.currentImapCredentials()
        _ = try await idleConnection.sendCommand(
            "LOGIN \(quoteAstring(creds.username)) \(quoteAstring(creds.password))"
        )
        _ = try await idleConnection.sendCommand(
            "SELECT \(quoteAstring(toServerPath(folder)))"
        )
        // IDLE has no tagged completion until DONE is issued, so it can't go
        // through `sendCommand`.
        try await idleConnection.writeRaw("I1 IDLE\r\n")
        while true {
            let response = try await idleConnection.readUntagged()
            if case .continuation = response { break }
            if case .completion(_, let status, let text) = response, status != .ok {
                throw CabalmailError.imapCommandFailed(status: status.rawValue, detail: text)
            }
        }
        return idleConnection
    }

    private nonisolated func makeIdleStream(
        idleConnection: ImapConnection
    ) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            let readerTask = Task { [idleConnection] in
                do {
                    while !Task.isCancelled {
                        let response = try await idleConnection.readUntagged()
                        switch response {
                        case .exists(let seq):   continuation.yield(IdleEvent(kind: .exists(seq)))
                        case .expunge(let seq):  continuation.yield(IdleEvent(kind: .expunge(seq)))
                        case .fetch(let seq, _): continuation.yield(IdleEvent(kind: .fetch(seq)))
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                readerTask.cancel()
                Task { [idleConnection] in
                    try? await idleConnection.writeRaw("DONE\r\n")
                    await idleConnection.close()
                }
            }
        }
    }
}

// MARK: - Internals

private extension LiveImapClient {
    func requireConnection() throws -> ImapConnection {
        guard let connection else {
            throw CabalmailError.notSignedIn
        }
        return connection
    }

    func select(folder: String, on conn: ImapConnection) async throws {
        if selectedFolder == folder { return }
        _ = try await conn.sendCommand("SELECT \(quoteAstring(toServerPath(folder)))")
        selectedFolder = folder
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
