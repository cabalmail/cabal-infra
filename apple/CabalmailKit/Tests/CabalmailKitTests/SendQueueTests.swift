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

    func testExceedingMaxAttemptsKeepsTheEntryMarkedFailed() async throws {
        // The message must survive running out of retries, so the user can
        // be told and decide (audit F8). It used to be deleted here.
        let outbox = try Outbox(directory: directory, maxAttempts: 2)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "give up"))
        let clock = TestClock()
        let queue = SendQueue(outbox: outbox, now: { clock.now }, sender: { _ in
            throw CabalmailError.network("always fails")
        })
        await queue.kickDrain()
        try await waitUntil {
            (try await outbox.list().first?.attempts ?? 0) == 1
        }
        clock.advance(by: 3600)
        await queue.kickDrain()
        try await waitUntil { (try await outbox.failed()).count == 1 }
        let entries = try await outbox.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.attempts, 2)
        XCTAssertEqual(entries.first?.failedAt, clock.now)
        XCTAssertNotNil(entries.first?.lastError)
        await queue.stop()
    }

    func testAFailedEntryIsNotRetriedUntilTheUserAsks() async throws {
        let outbox = try Outbox(directory: directory)
        let entry = try await outbox.enqueue(Self.makeMessage(subject: "parked"))
        var failed = entry
        failed.attempts = 10
        failed.failedAt = Date()
        try await outbox.update(failed)
        let sent = SentCounter()
        let queue = SendQueue(outbox: outbox) { _ in await sent.bump() }

        await queue.kickDrain()
        try await Task.sleep(nanoseconds: 200_000_000)
        let beforeRetry = await sent.count
        XCTAssertEqual(beforeRetry, 0, "a failed entry was drained without the user asking")

        try await outbox.resetForRetry(id: entry.id)
        await queue.kickDrain()
        try await waitUntil { try await outbox.count() == 0 }
        let afterRetry = await sent.count
        XCTAssertEqual(afterRetry, 1)
        await queue.stop()
    }

    func testAKickBeforeTheBackoffElapsesDoesNotSpendAnAttempt() async throws {
        // A flapping network kicks often; each kick must not cost a retry.
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "flappy"))
        let clock = TestClock()
        let calls = SentCounter()
        let queue = SendQueue(outbox: outbox, now: { clock.now }, sender: { _ in
            await calls.bump()
            throw CabalmailError.network("down again")
        })
        await queue.kickDrain()
        // The queue records a failed attempt, and the backoff it starts, only
        // after the sender throws, so wait for the outbox rather than the
        // sender's counter (#1858).
        try await waitUntil { await calls.count == 1 }
        try await waitUntil { (try await outbox.list().first?.attempts ?? 0) == 1 }

        for _ in 0..<5 {
            clock.advance(by: 1)
            await queue.kickDrain()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let duringBackoff = await calls.count
        XCTAssertEqual(duringBackoff, 1, "kicks inside the backoff window spent attempts")

        clock.advance(by: SendQueue.Backoff.standard.base)
        await queue.kickDrain()
        try await waitUntil { await calls.count == 2 }
        try await waitUntil { (try await outbox.list().first?.attempts ?? 0) == 2 }
        let entries = try await outbox.list()
        XCTAssertEqual(entries.first?.attempts, 2)
        await queue.stop()
    }

    func testTheQueueRetriesOnItsOwnWhenTheBackoffElapses() async throws {
        // No reachability change and no kick: the queue's own timer must
        // bring a deferred entry back, and keep at it until it gives up.
        let outbox = try Outbox(directory: directory, maxAttempts: 3)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "eventually"))
        let calls = SentCounter()
        let queue = SendQueue(
            outbox: outbox,
            backoff: SendQueue.Backoff(base: 0.05, cap: 0.05)
        ) { _ in
            await calls.bump()
            throw CabalmailError.network("still down")
        }
        await queue.kickDrain()
        try await waitUntil { (try await outbox.failed()).count == 1 }
        let total = await calls.count
        XCTAssertEqual(total, 3)
        await queue.stop()
    }

    func testAReconnectCutsALongBackoffToTheFirstStep() async throws {
        // Mail that failed many times during an outage shouldn't wait out an
        // hour-long backoff once the network is back.
        let outbox = try Outbox(directory: directory)
        let clock = TestClock()
        var entry = try await outbox.enqueue(Self.makeMessage(subject: "after the outage"))
        entry.attempts = 6
        entry.lastAttemptAt = clock.now
        try await outbox.update(entry)
        let sent = SentCounter()
        let queue = SendQueue(outbox: outbox, now: { clock.now }, sender: { _ in await sent.bump() })

        clock.advance(by: SendQueue.Backoff.standard.base + 1)
        await queue.kickDrain()
        try await Task.sleep(nanoseconds: 200_000_000)
        let beforeReconnect = await sent.count
        XCTAssertEqual(beforeReconnect, 0, "a plain kick skipped the backoff")

        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        await queue.bind(reachability: stream)
        continuation.yield(true)
        try await waitUntil { try await outbox.count() == 0 }
        let afterReconnect = await sent.count
        XCTAssertEqual(afterReconnect, 1)
        await queue.stop()
    }

    func testBackoffDoublesUpToTheCap() {
        let backoff = SendQueue.Backoff(base: 30, cap: 3600)
        XCTAssertEqual(backoff.delay(afterAttempts: 0), 30)
        XCTAssertEqual(backoff.delay(afterAttempts: 1), 30)
        XCTAssertEqual(backoff.delay(afterAttempts: 2), 60)
        XCTAssertEqual(backoff.delay(afterAttempts: 4), 240)
        XCTAssertEqual(backoff.delay(afterAttempts: 9), 3600)
        let fresh = Outbox.Entry(message: Self.makeMessage(subject: "new"))
        XCTAssertNil(backoff.nextAttempt(for: fresh), "a never-attempted entry is due at once")
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

    func testAMessageEnqueuedDuringADrainIsSentByTheSameDrain() async throws {
        // `CabalmailClient.send(_:)` enqueues and then kicks. The running
        // drain listed the outbox before that enqueue, so unless the kick is
        // honoured the new message sits there until the next reachability
        // transition (#1061).
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "first"))
        let gate = DrainGate()
        let sent = SentSubjects()
        let queue = SendQueue(outbox: outbox) { message in
            await sent.record(message.subject)
            if message.subject == "first" {
                await gate.markEntered()
                await gate.waitUntilOpen()
            }
        }
        await queue.kickDrain()
        try await waitUntil { await gate.entered }

        _ = try await outbox.enqueue(Self.makeMessage(subject: "second"))
        await queue.kickDrain()
        await gate.open()

        try await waitUntil { await sent.subjects.contains("second") }
        let remaining = try await outbox.count()
        XCTAssertEqual(remaining, 0, "a message enqueued mid-drain was left in the outbox")
        await queue.stop()
    }

    func testStoppingDuringADrainCancelsTheKickItWasHolding() async throws {
        // The coalesced kick must not outlive the queue: a drain retiring
        // after `stop()` has no business starting another one.
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "first"))
        let gate = DrainGate()
        let sent = SentSubjects()
        let queue = SendQueue(outbox: outbox) { message in
            await sent.record(message.subject)
            if message.subject == "first" {
                await gate.markEntered()
                await gate.waitUntilOpen()
            }
        }
        await queue.kickDrain()
        try await waitUntil { await gate.entered }

        _ = try await outbox.enqueue(Self.makeMessage(subject: "second"))
        await queue.kickDrain()
        await queue.stop()
        await gate.open()

        try await Task.sleep(nanoseconds: 300_000_000)
        let subjects = await sent.subjects
        XCTAssertFalse(subjects.contains("second"), "a stopped queue started another drain")
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

private actor SentSubjects {
    private(set) var subjects: [String] = []
    func record(_ subject: String) { subjects.append(subject) }
}

/// Holds a drain open from inside the sender closure so the test can enqueue
/// against a pass that is provably in flight.
private actor DrainGate {
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
