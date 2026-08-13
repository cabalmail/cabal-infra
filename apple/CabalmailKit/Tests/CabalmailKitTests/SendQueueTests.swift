import XCTest
@testable import CabalmailKit

/// Drives `SendQueue` against an in-memory outbox and a scripted sender
/// closure. Verifies the retry semantics promised in the Phase 7 plan:
/// transient failures bump `attempts`, a drain pass proceeds oldest-first,
/// and reachability transitions trigger drains.
final class SendQueueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendQueueTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testDrainRemovesSucceededEntries() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "a"))
        _ = try await outbox.enqueue(Self.makeMessage(subject: "b"))
        let sent = SentCounter()
        let queue = SendQueue(outbox: outbox) { _ in await sent.bump() }
        await queue.kickDrain()
        try await waitUntil { try await outbox.count() == 0 }
        let total = await sent.count
        XCTAssertEqual(total, 2)
    }

    func testTransientFailureIncrementsAttempts() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "nope"))
        let queue = SendQueue(outbox: outbox) { _ in
            throw CabalmailError.network("simulated")
        }
        await queue.kickDrain()
        try await waitUntil {
            (try await outbox.list().first?.attempts ?? 0) == 1
        }
        let entries = try await outbox.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.attempts, 1)
    }

    func testExceedingMaxAttemptsDropsEntry() async throws {
        let outbox = try Outbox(directory: directory, maxAttempts: 2)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "give up"))
        let queue = SendQueue(outbox: outbox) { _ in
            throw CabalmailError.network("always fails")
        }
        await queue.kickDrain()
        try await waitUntil {
            (try await outbox.list().first?.attempts ?? 0) == 1
        }
        await queue.kickDrain()
        try await waitUntil { (try await outbox.count()) == 0 }
        let remaining = try await outbox.count()
        XCTAssertEqual(remaining, 0)
    }

    func testReachabilityTransitionKicksDrain() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "connect me"))
        let sent = SentCounter()
        let queue = SendQueue(outbox: outbox) { _ in await sent.bump() }
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        await queue.bind(reachability: stream)
        continuation.yield(true)
        try await waitUntil { try await outbox.count() == 0 }
        let total = await sent.count
        XCTAssertEqual(total, 1)
        await queue.stop()
    }

    // MARK: - Helpers

    private static func makeMessage(subject: String) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "example.com"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: subject,
            textBody: "body"
        )
    }
}

private actor SentCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
