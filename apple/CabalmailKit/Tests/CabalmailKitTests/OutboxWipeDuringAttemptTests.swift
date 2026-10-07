import XCTest
@testable import CabalmailKit

/// A drain attempt must not bring back an entry that left the outbox while
/// the attempt ran (#1909).
///
/// Sign-out wipes the outbox (`clearLocalData`) and ends the auth session
/// before it shuts the client down and stops its send queue. A drain whose
/// send fails in that window used to write its entry back after the wipe,
/// and the outbox is shared by every account on the device, so the next
/// account's queue would send the previous account's message. `stop()`
/// already kept an attempt it cancelled from writing back (#1887); this is
/// the attempt that fails before `stop()` arrives.
final class OutboxWipeDuringAttemptTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxWipeDuringAttemptTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAnAttemptThatFailsAfterTheWipeLeavesTheOutboxEmpty() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "previous account"))
        let sender = HeldSender()
        let queue = SendQueue(outbox: outbox, sender: sender.send)

        await queue.kickDrain()
        try await waitUntil { await sender.isHolding }
        try await outbox.removeAll()
        await sender.releaseFailing(with: CabalmailError.notSignedIn)
        try await finishPass(outbox: outbox, queue: queue, sender: sender)

        let left = try await outbox.list()
        XCTAssertEqual(left.map(\.message.subject), [], "the wiped entry came back")
        await queue.stop()
    }

    /// The control: the same failed attempt with the entry still queued is
    /// recorded on it, so the test above is measuring the wipe.
    func testAnAttemptThatFailsWithTheEntryStillQueuedIsRecorded() async throws {
        let outbox = try Outbox(directory: directory)
        let queued = try await outbox.enqueue(Self.makeMessage(subject: "still queued"))
        let sender = HeldSender()
        let queue = SendQueue(outbox: outbox, sender: sender.send)

        await queue.kickDrain()
        try await waitUntil { await sender.isHolding }
        await sender.releaseFailing(with: CabalmailError.notSignedIn)
        try await finishPass(outbox: outbox, queue: queue, sender: sender)

        let left = try await outbox.list()
        XCTAssertEqual(left.map(\.id), [queued.id])
        XCTAssertEqual(left.first?.attempts, 1)
        XCTAssertNotNil(left.first?.lastError)
        await queue.stop()
    }

    func testUpdatingAnEntryThatWasRemovedLeavesItRemoved() async throws {
        let outbox = try Outbox(directory: directory)
        var entry = try await outbox.enqueue(Self.makeMessage(subject: "discarded"))
        try await outbox.remove(id: entry.id)
        entry.attempts = 1

        let written = try await outbox.update(entry)

        XCTAssertFalse(written)
        let left = try await outbox.list()
        XCTAssertTrue(left.isEmpty)
    }

    /// Queues a marker and kicks: the drain in flight takes the kick as one
    /// more pass after the held attempt, so once the marker has been sent,
    /// the held attempt's write-back (or its absence) has happened. The
    /// marker leaves the outbox when it is sent.
    private func finishPass(outbox: Outbox, queue: SendQueue, sender: HeldSender) async throws {
        _ = try await outbox.enqueue(Self.makeMessage(subject: "marker"))
        await queue.kickDrain()
        try await waitUntil { await sender.sentSubjects.contains("marker") }
        try await waitUntil { try await !outbox.list().contains { $0.message.subject == "marker" } }
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

/// A sender whose first call parks until the test releases it with an
/// error; every later call succeeds and records its subject.
private actor HeldSender {
    private(set) var isHolding = false
    private(set) var sentSubjects: [String] = []
    private var held: CheckedContinuation<Error, Never>?
    private var heldOnce = false

    nonisolated var send: SendQueue.Sender {
        { message in try await self.attempt(message) }
    }

    func releaseFailing(with error: Error) {
        held?.resume(returning: error)
        held = nil
    }

    private func attempt(_ message: OutgoingMessage) async throws {
        guard !heldOnce else {
            sentSubjects.append(message.subject)
            return
        }
        heldOnce = true
        let error = await withCheckedContinuation { continuation in
            held = continuation
            isHolding = true
        }
        throw error
    }
}
