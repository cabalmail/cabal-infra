import XCTest
@testable import CabalmailKit

/// A queued message must not be discarded because the API refused to send it
/// twice (#1019).
///
/// `/send` claims the Message-Id across the SMTP handoff, and the Apple outbox
/// re-submits the same stamped id on every drain. It used to answer any
/// duplicate with the byte-identical `200 {"status":"submitted"}` a real
/// delivery gets, so `SendQueue` deleted the queued message and logged it as
/// sent — even when the claim was orphaned by a handler that died mid-send and
/// nothing had been delivered. It now answers a claim it cannot prove delivered
/// with `409 {"status":"duplicate_in_flight"}`, and the queue holds the
/// message until the claim clears.
///
/// The two halves are tested where they live: the wire mapping on
/// `URLSessionApiClient.sendMessage`, the retention on `SendQueue`.
final class SendDuplicateInFlightTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendDuplicateInFlightTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Wire mapping

    func testUnprovenDuplicateSurfacesAsSendInFlight() async throws {
        let body = #"{"status":"duplicate_in_flight","message":"An earlier submission is in flight."}"#
        let client = makeClient(responses: [(Data(body.utf8), 409)])
        do {
            try await client.sendMessage(Self.makeRequest())
            XCTFail("an unproven duplicate was reported as a successful send")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .sendInFlight)
        }
    }

    func testProvenDuplicateStillReadsAsSuccess() async throws {
        // The dedupe's whole purpose: once the server can show the message
        // went out, the client must stop retrying rather than earn itself a
        // second copy after the claim's TTL.
        let body = #"{"status":"submitted","duplicate":true}"#
        let client = makeClient(responses: [(Data(body.utf8), 200)])
        try await client.sendMessage(Self.makeRequest())
    }

    func testUnrelatedConflictIsNotMistakenForAnInFlightSend() async throws {
        // Only /send's own duplicate body earns the new case; any other 409
        // keeps the generic server error so it still reaches the user.
        let body = #"{"status":"That message is no longer in Drafts"}"#
        let client = makeClient(responses: [(Data(body.utf8), 409)])
        do {
            try await client.sendMessage(Self.makeRequest())
            XCTFail("a rejected send was reported as successful")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(code: "409", message: body))
        }
    }

    func testSendInFlightIsAQueueableFailure() {
        // The foreground path has the same stake as the drain: a claim the
        // server can't resolve is not a reason to hand the user an error and
        // drop what they wrote.
        XCTAssertTrue(CabalmailClient.shouldQueue(.sendInFlight))
    }

    // MARK: - Queue retention

    func testInFlightDuplicateKeepsTheQueuedMessage() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "still claimed"))
        let queue = SendQueue(outbox: outbox) { _ in
            throw CabalmailError.sendInFlight
        }
        await queue.kickDrain()
        try await Self.waitUntil {
            (try await outbox.list().first?.lastAttemptAt) != nil
        }
        let entries = try await outbox.list()
        XCTAssertEqual(entries.count, 1, "the queued message was discarded as sent")
        // The attempt says nothing about the message's fate, so it must not
        // be charged against the retry budget.
        XCTAssertEqual(entries.first?.attempts, 0)
    }

    func testRepeatedInFlightDuplicatesNeverExhaustTheRetryBudget() async throws {
        // The loss the attempt counter would otherwise reintroduce: a claim
        // that outlives a few drains would run the entry into maxAttempts and
        // drop a message that was never sent.
        let outbox = try Outbox(directory: directory, maxAttempts: 2)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "claimed for a while"))
        let refusals = RefusalCounter()
        let queue = SendQueue(outbox: outbox) { _ in
            await refusals.bump()
            throw CabalmailError.sendInFlight
        }
        for pass in 1...4 {
            await queue.kickDrain()
            try await Self.waitUntil { await refusals.count >= pass }
        }
        let remaining = try await outbox.count()
        XCTAssertEqual(remaining, 1, "the message was dropped while its claim was unresolved")
    }

    func testARealFailureStillSpendsAnAttempt() async throws {
        // Guarding the new branch's blast radius: only the in-flight answer
        // is free, everything else retries on the budget it always had.
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "really failed"))
        let queue = SendQueue(outbox: outbox) { _ in
            throw CabalmailError.network("simulated")
        }
        await queue.kickDrain()
        try await Self.waitUntil {
            (try await outbox.list().first?.attempts ?? 0) == 1
        }
        let entries = try await outbox.list()
        XCTAssertEqual(entries.first?.attempts, 1)
    }

    // MARK: - Helpers

    private func makeClient(responses: [(Data, Int)]) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: RecordingHTTPTransport(responses: responses)
        )
    }

    private static func makeRequest() -> SendMessageRequest {
        SendMessageRequest(
            host: "imap.cabalmail.example",
            smtpHost: "smtp.cabalmail.example",
            sender: "alice@cabalmail.example",
            toList: ["bob@example.com"],
            ccList: [],
            bccList: [],
            subject: "claimed",
            otherHeaders: ApiSendOtherHeaders(messageId: ["<claimed@cabalmail.example>"]),
            htmlBody: "<p>body</p>",
            textBody: "body",
            draft: false
        )
    }

    private static func makeMessage(subject: String) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: subject,
            textBody: "body",
            messageId: "<claimed@cabalmail.example>"
        )
    }

    /// Same polling idiom as `SendQueueTests`: the queue runs on its own
    /// actor, so a drain can't be awaited from the outside.
    private static func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never met within 2s")
    }
}

private actor RefusalCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
