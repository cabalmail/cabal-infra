import XCTest
@testable import CabalmailKit

final class ImapClientTests: XCTestCase {
    private func signIn(on client: LiveImapClient, stream: ScriptedByteStream) async throws {
        await stream.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await stream.enqueue("A1 OK LOGIN completed\r\n")
        try await client.connectAndAuthenticate()
    }

    func testConnectAuthenticatesWithLoginCommand() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("LOGIN \"alice\" \"hunter2\""))
    }

    func testListFoldersReturnsParsedHierarchy() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue(#"* LIST (\HasNoChildren) "." "INBOX"\#r\#n"#)
        await stream.enqueue(#"* LIST (\HasChildren) "." "Archive"\#r\#n"#)
        await stream.enqueue(#"* LIST (\HasNoChildren) "." "Archive.2024"\#r\#n"#)
        await stream.enqueue("A2 OK LIST completed\r\n")
        await stream.enqueue(#"* LSUB () "." "INBOX"\#r\#n"#)
        await stream.enqueue("A3 OK LSUB completed\r\n")

        let folders = try await client.listFolders()
        let paths = folders.map(\.path).sorted()
        XCTAssertEqual(paths, ["Archive", "Archive/2024", "INBOX"])
        let inbox = folders.first { $0.path == "INBOX" }
        XCTAssertEqual(inbox?.isSubscribed, true)
        let archive = folders.first { $0.path == "Archive" }
        XCTAssertEqual(archive?.isSubscribed, false)
    }

    func testStatusReturnsCounters() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue(#"* STATUS "INBOX" (MESSAGES 42 UNSEEN 5 UIDVALIDITY 1700000000 UIDNEXT 100)\#r\#n"#)
        await stream.enqueue("A2 OK STATUS completed\r\n")

        let status = try await client.status(path: "INBOX")
        XCTAssertEqual(status.messages, 42)
        XCTAssertEqual(status.unseen, 5)
        XCTAssertEqual(status.uidValidity, 1_700_000_000)
        XCTAssertEqual(status.uidNext, 100)
    }

    func testFetchEnvelopesParsesFields() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("* 10 EXISTS\r\n")
        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        let envelopeLine = [
            "* 1 FETCH (UID 42 FLAGS (\\Seen) INTERNALDATE \"01-Jan-2024 10:00:00 +0000\" ",
            "RFC822.SIZE 1234 ENVELOPE (\"Mon, 1 Jan 2024 10:00:00 +0000\" \"Hello\" ",
            "((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Alice\" NIL \"alice\" \"example.com\")) ",
            "((\"Alice\" NIL \"alice\" \"example.com\")) ((\"Bob\" NIL \"bob\" \"example.com\")) ",
            "NIL NIL NIL \"<id-42@example.com>\") BODYSTRUCTURE (\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 10))\r\n",
            "A3 OK UID FETCH completed\r\n",
        ].joined()
        await stream.enqueue(envelopeLine)

        let envelopes = try await client.envelopes(folder: "INBOX", range: 1...50)
        XCTAssertEqual(envelopes.count, 1)
        let envelope = envelopes[0]
        XCTAssertEqual(envelope.uid, 42)
        XCTAssertEqual(envelope.subject, "Hello")
        XCTAssertEqual(envelope.from.first?.mailbox, "alice")
        XCTAssertEqual(envelope.to.first?.mailbox, "bob")
        XCTAssertEqual(envelope.messageId, "<id-42@example.com>")
        XCTAssertTrue(envelope.flags.contains(.seen))
    }

    func testFetchBodyReturnsLiteralBytes() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        let body = "Subject: Hi\r\n\r\nHello world\r\n"
        let bodyBytes = Data(body.utf8)
        let header = "* 1 FETCH (UID 42 FLAGS (\\Seen) BODY[] {\(bodyBytes.count)}\r\n"
        await stream.enqueue(Data(header.utf8))
        await stream.enqueue(bodyBytes)
        await stream.enqueue(")\r\n")
        await stream.enqueue("A3 OK UID FETCH completed\r\n")

        let raw = try await client.fetchBody(folder: "INBOX", uid: 42)
        XCTAssertEqual(raw.uid, 42)
        XCTAssertEqual(raw.bytes, bodyBytes)
        XCTAssertTrue(raw.flags.contains(.seen))
    }

    func testSetFlagsEmitsStore() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        await stream.enqueue("* 1 FETCH (UID 10 FLAGS (\\Seen))\r\n")
        await stream.enqueue("A3 OK UID STORE completed\r\n")

        try await client.setFlags(folder: "INBOX", uids: [10, 11], flags: [.seen], operation: .add)
        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("UID STORE 10,11 +FLAGS (\\Seen)"))
    }

    func testMoveFallsBackToCopyExpunge() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        await stream.enqueue("A3 NO MOVE not supported\r\n")
        await stream.enqueue("A4 OK UID COPY completed\r\n")
        await stream.enqueue("A5 OK UID STORE completed\r\n")
        await stream.enqueue("A6 OK UID EXPUNGE completed\r\n")

        try await client.move(folder: "INBOX", uids: [7], destination: "Archive")
        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("UID COPY 7 \"Archive\""))
        XCTAssertTrue(outbound.contains("UID STORE 7 +FLAGS (\\Deleted)"))
        XCTAssertTrue(outbound.contains("UID EXPUNGE 7"))
    }

    func testTransportErrorTriggersReconnectAndRetry() async throws {
        // Stream 1 completes LOGIN, then throws a transport error on the
        // next read — simulating a socket that's been on the far side of a
        // sleep/wake while the laptop switched networks.
        let stale = ScriptedByteStream()
        await stale.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await stale.enqueue("A1 OK LOGIN completed\r\n")
        await stale.enqueueError(CabalmailError.transport("Socket is not connected"))

        // Stream 2 is a fresh socket: greeting, LOGIN on the new connection,
        // then the LIST / LSUB responses the retry actually consumes.
        let fresh = ScriptedByteStream()
        await fresh.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await fresh.enqueue("A1 OK LOGIN completed\r\n")
        await fresh.enqueue(#"* LIST (\HasNoChildren) "." "INBOX"\#r\#n"#)
        await fresh.enqueue("A2 OK LIST completed\r\n")
        await fresh.enqueue(#"* LSUB () "." "INBOX"\#r\#n"#)
        await fresh.enqueue("A3 OK LSUB completed\r\n")

        let factory = RotatingConnectionFactory(streams: [stale, fresh])
        let client = LiveImapClient(factory: factory, authService: StubAuthService())
        try await client.connectAndAuthenticate()

        let folders = try await client.listFolders()
        XCTAssertEqual(folders.map(\.path), ["INBOX"])

        let madeCount = await factory.madeCount
        XCTAssertEqual(madeCount, 2, "Retry should have opened a second connection")

        let freshOutbound = await fresh.outboundString
        XCTAssertTrue(freshOutbound.contains("LOGIN \"alice\" \"hunter2\""))
        XCTAssertTrue(freshOutbound.contains("LIST \"\" \"*\""))
    }

    func testTransportErrorRetryReSelectsFolder() async throws {
        // After a stale-socket failure, the retry must SELECT the mailbox
        // again on the fresh connection before re-issuing the UID FETCH —
        // the reset of `selectedFolder` during invalidate is what guarantees
        // this.
        let stale = ScriptedByteStream()
        await stale.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await stale.enqueue("A1 OK LOGIN completed\r\n")
        await stale.enqueueError(CabalmailError.transport("Socket is not connected"))

        let fresh = ScriptedByteStream()
        await fresh.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await fresh.enqueue("A1 OK LOGIN completed\r\n")
        await fresh.enqueue("* 10 EXISTS\r\n")
        await fresh.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        let body = "Subject: Hi\r\n\r\nHello world\r\n"
        let bodyBytes = Data(body.utf8)
        let header = "* 1 FETCH (UID 42 FLAGS (\\Seen) BODY[] {\(bodyBytes.count)}\r\n"
        await fresh.enqueue(Data(header.utf8))
        await fresh.enqueue(bodyBytes)
        await fresh.enqueue(")\r\n")
        await fresh.enqueue("A3 OK UID FETCH completed\r\n")

        let factory = RotatingConnectionFactory(streams: [stale, fresh])
        let client = LiveImapClient(factory: factory, authService: StubAuthService())
        try await client.connectAndAuthenticate()

        let raw = try await client.fetchBody(folder: "INBOX", uid: 42)
        XCTAssertEqual(raw.uid, 42)
        XCTAssertEqual(raw.bytes, bodyBytes)

        let freshOutbound = await fresh.outboundString
        XCTAssertTrue(freshOutbound.contains("SELECT \"INBOX\""))
        XCTAssertTrue(freshOutbound.contains("UID FETCH 42"))
    }

    func testNonTransportErrorIsNotRetried() async throws {
        // Server-level errors (IMAP NO/BAD) aren't a transport problem — the
        // retry path should leave them alone so we don't double-submit
        // commands that the server already rejected.
        let stale = ScriptedByteStream()
        let fresh = ScriptedByteStream()
        let factory = RotatingConnectionFactory(streams: [stale, fresh])
        let client = LiveImapClient(factory: factory, authService: StubAuthService())
        try await signIn(on: client, stream: stale)

        await stale.enqueue("A2 NO CREATE failed: invalid mailbox name\r\n")
        do {
            try await client.createFolder(name: "bad/../name", parent: nil)
            XCTFail("Expected .imapCommandFailed")
        } catch CabalmailError.imapCommandFailed {
            // expected — and no reconnect should have happened
        }

        let madeCount = await factory.madeCount
        XCTAssertEqual(madeCount, 1, "Server-level error should not open a second connection")
    }

    func testFolderDelimiterTranslation() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue(#"* LIST () "." "INBOX"\#r\#n"#)
        await stream.enqueue("A2 OK LIST\r\n")
        await stream.enqueue("A3 OK LSUB\r\n")
        _ = try await client.listFolders()

        await stream.enqueue("A4 OK CREATE completed\r\n")
        try await client.createFolder(name: "2024", parent: "Archive")
        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("CREATE \"Archive.2024\""))
    }
}

// Coverage for `topEnvelopes(folder:limit:totalMessages:)`. Lifted into a
// same-file extension so the primary `ImapClientTests` body stays under
// SwiftLint's 250-line cap; XCTest discovers test methods across extensions.
extension ImapClientTests {
    func testTopEnvelopesUsesSequenceFetchForSmallFolder() async throws {
        // Regression coverage for the "Apple client only shows 3 of 19 inbox
        // messages" bug: a long-lived Inbox where UIDNEXT is well past
        // pageSize but only a handful of messages remain would return just
        // the messages whose UIDs happened to land in the top-50 UID band.
        // Sequence-number FETCH is the fix — `1:*` here covers the full
        // folder regardless of UID density.
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("* 19 EXISTS\r\n")
        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        let envelopeLine = [
            "* 1 FETCH (UID 784 FLAGS (\\Seen) INTERNALDATE \"01-Jan-2024 10:00:00 +0000\" ",
            "RFC822.SIZE 42 ENVELOPE (\"Mon, 1 Jan 2024 10:00:00 +0000\" \"Hi\" ",
            "((\"A\" NIL \"a\" \"example.com\")) ((\"A\" NIL \"a\" \"example.com\")) ",
            "((\"A\" NIL \"a\" \"example.com\")) ((\"B\" NIL \"b\" \"example.com\")) ",
            "NIL NIL NIL \"<x@example.com>\") BODYSTRUCTURE (\"text\" \"plain\" NIL NIL NIL \"7bit\" 10 1))\r\n",
            "A3 OK FETCH completed\r\n",
        ].joined()
        await stream.enqueue(envelopeLine)

        let fetched = try await client.topEnvelopes(folder: "INBOX", limit: 50, totalMessages: 19)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.uid, 784)

        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("FETCH 1:* "), "expected sequence FETCH 1:*, got: \(outbound)")
        XCTAssertFalse(outbound.contains("UID FETCH"), "top-page fetch must not use UID FETCH")
    }

    func testTopEnvelopesClampsStartWhenExceedingLimit() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        await stream.enqueue("* 200000 EXISTS\r\n")
        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        await stream.enqueue("A3 OK FETCH completed\r\n")

        _ = try await client.topEnvelopes(folder: "INBOX", limit: 50, totalMessages: 200_000)

        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("FETCH 199951:* "), "expected FETCH 199951:*, got: \(outbound)")
    }

    func testTopEnvelopesSkipsWireWhenFolderEmpty() async throws {
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        let fetched = try await client.topEnvelopes(folder: "INBOX", limit: 50, totalMessages: 0)
        XCTAssertTrue(fetched.isEmpty)

        let outbound = await stream.outboundString
        XCTAssertFalse(outbound.contains("SELECT"))
        XCTAssertFalse(outbound.contains("FETCH"))
    }

    func testFailedSelectResetsCacheSoNextSelectReissues() async throws {
        // Regression coverage for issue #356: when a SELECT fails (e.g. the
        // user-visible folder was deleted by another client), the server
        // transitions back to AUTHENTICATED per RFC 3501 §6.3.1. If we keep
        // the previous `selectedFolder` cached, the next select(previous)
        // call would short-circuit and the following UID FETCH would crash
        // into "No mailbox selected." A failed SELECT must clear the cache.
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        // First fetch: SELECT INBOX succeeds, UID FETCH 1 succeeds.
        await stream.enqueue("* 1 EXISTS\r\n")
        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        let body = "ok\r\n"
        let bodyBytes = Data(body.utf8)
        let header = "* 1 FETCH (UID 1 FLAGS () BODY[] {\(bodyBytes.count)}\r\n"
        await stream.enqueue(Data(header.utf8))
        await stream.enqueue(bodyBytes)
        await stream.enqueue(")\r\n")
        await stream.enqueue("A3 OK UID FETCH completed\r\n")
        _ = try await client.fetchBody(folder: "INBOX", uid: 1)

        // Second op: SELECT Ghost fails — server is now in AUTHENTICATED.
        await stream.enqueue("A4 NO [NONEXISTENT] Mailbox doesn't exist\r\n")
        do {
            _ = try await client.fetchBody(folder: "Ghost", uid: 1)
            XCTFail("Expected SELECT to fail for nonexistent mailbox")
        } catch CabalmailError.imapCommandFailed {
            // expected
        }

        // Third op back on INBOX must re-issue SELECT (cache was cleared).
        // Without the fix, `selectedFolder` would still equal "INBOX" from
        // the first fetch and the FETCH below would land before any SELECT.
        await stream.enqueue("* 1 EXISTS\r\n")
        await stream.enqueue("A5 OK [READ-WRITE] SELECT completed\r\n")
        let secondHeader = "* 1 FETCH (UID 1 FLAGS () BODY[] {\(bodyBytes.count)}\r\n"
        await stream.enqueue(Data(secondHeader.utf8))
        await stream.enqueue(bodyBytes)
        await stream.enqueue(")\r\n")
        await stream.enqueue("A6 OK UID FETCH completed\r\n")
        _ = try await client.fetchBody(folder: "INBOX", uid: 1)

        let outbound = await stream.outboundString
        // Three SELECTs in total: the initial INBOX, the failed Ghost, and
        // the post-failure re-SELECT of INBOX.
        let inboxSelects = outbound.components(separatedBy: "SELECT \"INBOX\"").count - 1
        XCTAssertEqual(inboxSelects, 2, "INBOX must be re-SELECTed after a failed SELECT cleared the cache")
        XCTAssertTrue(outbound.contains("SELECT \"Ghost\""))
    }

    func testNoMailboxSelectedTriggersReSelectAndRetry() async throws {
        // Defense-in-depth: even if our `selectedFolder` cache is somehow
        // out of sync with the server (e.g., concurrent ops on the same
        // actor interleaved a failed SELECT we didn't observe directly),
        // a "No mailbox selected" response should drop the cache and let
        // the operation re-run, re-issuing SELECT once. The user shouldn't
        // see this surface as a UI error.
        let stream = ScriptedByteStream()
        let client = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        try await signIn(on: client, stream: stream)

        // setFlags first run: SELECT INBOX, then UID STORE returns BAD with
        // "No mailbox selected" (server unselected for some reason).
        await stream.enqueue("* 0 EXISTS\r\n")
        await stream.enqueue("A2 OK [READ-WRITE] SELECT completed\r\n")
        await stream.enqueue("A3 BAD No mailbox selected.\r\n")

        // Retry: cache was cleared, so SELECT INBOX must be re-issued, then
        // UID STORE retries and succeeds.
        await stream.enqueue("* 0 EXISTS\r\n")
        await stream.enqueue("A4 OK [READ-WRITE] SELECT completed\r\n")
        await stream.enqueue("A5 OK UID STORE completed\r\n")

        try await client.setFlags(folder: "INBOX", uids: [10], flags: [.seen], operation: .add)

        let outbound = await stream.outboundString
        let inboxSelects = outbound.components(separatedBy: "SELECT \"INBOX\"").count - 1
        XCTAssertEqual(inboxSelects, 2, "Recovery path must SELECT INBOX a second time before retrying UID STORE")
        let stores = outbound.components(separatedBy: "UID STORE").count - 1
        XCTAssertEqual(stores, 2, "UID STORE must be retried once after the No-mailbox-selected error")
    }
}
