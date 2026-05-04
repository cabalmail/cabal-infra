import XCTest
@testable import CabalmailKit

/// Coverage for the SELECTed-mailbox cache invalidation path added for
/// issue #356. Lives in its own XCTestCase subclass to keep
/// `ImapClientTests.swift` under SwiftLint's file_length cap.
final class ImapClientSelectCacheTests: XCTestCase {
    private func signIn(on client: LiveImapClient, stream: ScriptedByteStream) async throws {
        await stream.enqueue("* OK IMAP4rev1 Service Ready\r\n")
        await stream.enqueue("A1 OK LOGIN completed\r\n")
        try await client.connectAndAuthenticate()
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
