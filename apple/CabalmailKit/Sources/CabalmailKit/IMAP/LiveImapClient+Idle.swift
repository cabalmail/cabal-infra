import Foundation

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
        let idleConnection = try await openAuthenticatedConnection()
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
