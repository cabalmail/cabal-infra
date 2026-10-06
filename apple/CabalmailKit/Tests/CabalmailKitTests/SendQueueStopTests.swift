import XCTest
@testable import CabalmailKit

/// `SendQueue.stop()` is for good: `CabalmailClient.shutdown()` calls it when
/// the app lets a client go, and the outbox it drained is the one every
/// client is built over. A stopped queue starts nothing again, and an
/// attempt the stop interrupts writes nothing back: the outbox may have been
/// wiped meanwhile (a sign-out does that, then shuts the client down).
final class SendQueueStopTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendQueueStopTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAStoppedQueueIgnoresAKickAndAReconnect() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "queued"))
        let sends = Counter()
        let queue = SendQueue(outbox: outbox) { _ in await sends.bump() }

        await queue.stop()
        await queue.kickDrain()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        await queue.bind(reachability: stream)
        continuation.yield(true)

        try await Task.sleep(nanoseconds: 300_000_000)
        let count = await sends.count
        XCTAssertEqual(count, 0, "a stopped queue drained")
        let left = try await outbox.list()
        XCTAssertEqual(left.count, 1, "the message stays queued")
        continuation.finish()
    }

    func testAnAttemptStoppedMidSendLeavesItsEntryAsItWas() async throws {
        // The stop cancels the drain in flight, so the send it interrupts
        // fails. That failure says nothing about the message: the attempt
        // must not count it, or mark it failed.
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "held"))
        let gate = Gate()
        let queue = SendQueue(outbox: outbox) { _ in
            await gate.markEntered()
            await gate.waitUntilOpen()
            throw CabalmailError.network("cancelled")
        }
        await queue.kickDrain()
        try await waitUntil { await gate.entered }

        await queue.stop()
        await gate.open()

        try await Task.sleep(nanoseconds: 300_000_000)
        let left = try await outbox.list()
        XCTAssertEqual(left.map(\.attempts), [0], "the interrupted attempt wrote nothing back")
        XCTAssertNil(left.first?.lastError)
    }

    func testAnAttemptStoppedMidSendDoesNotBringBackAWipedEntry() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "held"))
        let gate = Gate()
        let queue = SendQueue(outbox: outbox) { _ in
            await gate.markEntered()
            await gate.waitUntilOpen()
            throw CabalmailError.network("cancelled")
        }
        await queue.kickDrain()
        try await waitUntil { await gate.entered }

        try await outbox.removeAll()
        await queue.stop()
        await gate.open()

        try await Task.sleep(nanoseconds: 300_000_000)
        let left = try await outbox.list()
        XCTAssertEqual(left, [], "the wiped entry came back")
    }

    private static func makeMessage(subject: String) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "example.com"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: subject,
            textBody: "body"
        )
    }
}

private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Holds a send in flight until opened.
private actor Gate {
    private(set) var entered = false
    private var isOpen = false

    func markEntered() { entered = true }
    func open() { isOpen = true }

    func waitUntilOpen() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
