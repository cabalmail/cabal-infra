import Synchronization
import XCTest
@testable import CabalmailKit

/// A message the sender delivered stays delivered when its outbox file can't
/// be removed: the queue never sends it again while it runs, retries only the
/// removal, and says so once in the Debug Log. Before, the removal's failure
/// vanished, and an entry with an earlier failed attempt came straight back
/// due, so the retry timer re-sent it with no delay until the file went.
final class SendQueueDeliveredTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendQueueDeliveredTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testADeliveredEntryWhoseRemovalFailsIsNotSentAgain() async throws {
        let files = FailingFileManager()
        let outbox = try Outbox(directory: directory, fileManager: files)
        let clock = TestClock()
        // An earlier failed attempt, long enough ago that the entry is due:
        // the case that used to loop on the retry timer.
        var entry = try await outbox.enqueue(Self.makeMessage(subject: "once"))
        entry.attempts = 1
        entry.lastAttemptAt = clock.now.addingTimeInterval(-3600)
        try await outbox.update(entry)
        let sends = Counter()
        let queue = SendQueue(outbox: outbox, now: { clock.now }, sender: { _ in await sends.bump() })
        files.failRemovals(true)

        await queue.kickDrain()
        try await waitUntil { files.removalAttempts == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<3 {
            await queue.kickDrain()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let sent = await sends.count
        XCTAssertEqual(sent, 1, "a delivered message was sent again")
        XCTAssertEqual(files.removalAttempts, 1, "the removal was retried before its backoff")
        let remaining = try await outbox.count()
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(
            Self.lines(mentioning: entry.id.uuidString).map(\.level),
            [.info, .error],
            "expected the send, then one error for the failed removal"
        )

        files.failRemovals(false)
        clock.advance(by: SendQueue.Backoff.standard.base)
        await queue.kickDrain()
        try await waitUntil { try await outbox.count() == 0 }
        let sentAfterRemoval = await sends.count
        XCTAssertEqual(sentAfterRemoval, 1, "the drain that retried the removal sent the message again")
        XCTAssertTrue(
            Self.lines(mentioning: entry.id.uuidString).contains {
                $0.level == .info && $0.message.hasPrefix("removed delivered")
            },
            "the removal's recovery wasn't logged"
        )
        await queue.stop()
    }

    func testTheQueueRetriesTheRemovalOnItsOwnAndLogsTheFailureOnce() async throws {
        // A never-attempted entry used to come back only on the next kick,
        // and be sent again then. Now the retry timer retries the removal
        // alone, with no kick, and a run of failures logs one error.
        let files = FailingFileManager()
        let outbox = try Outbox(directory: directory, fileManager: files)
        let entry = try await outbox.enqueue(Self.makeMessage(subject: "fresh"))
        let sends = Counter()
        let queue = SendQueue(
            outbox: outbox,
            backoff: SendQueue.Backoff(base: 0.05, cap: 0.05)
        ) { _ in await sends.bump() }
        files.failRemovals(true)

        await queue.kickDrain()
        try await waitUntil { files.removalAttempts >= 3 }
        files.failRemovals(false)
        try await waitUntil { try await outbox.count() == 0 }

        let sent = await sends.count
        XCTAssertEqual(sent, 1)
        let errors = Self.lines(mentioning: entry.id.uuidString).filter { $0.level == .error }
        XCTAssertEqual(errors.count, 1, "each failed removal was logged: \(errors.map(\.message))")
        await queue.stop()
    }

    func testAnOutboxThatCannotBeListedIsLoggedNotTakenAsEmpty() async throws {
        let files = FailingFileManager()
        let outbox = try Outbox(directory: directory, fileManager: files)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "waiting"))
        let sends = Counter()
        let queue = SendQueue(outbox: outbox) { _ in await sends.bump() }
        let token = files.failListing(true)

        do {
            _ = try await outbox.list()
            XCTFail("listing an unreadable outbox returned entries")
        } catch {
            XCTAssertTrue("\(error)".contains(token))
        }
        await queue.kickDrain()
        try await waitUntil {
            Self.lines(mentioning: token).contains { $0.level == .error && $0.message.contains("for the drain") }
        }
        let sentWhileUnreadable = await sends.count
        XCTAssertEqual(sentWhileUnreadable, 0)

        files.failListing(false)
        await queue.kickDrain()
        try await waitUntil { try await outbox.count() == 0 }
        await queue.stop()
    }

    func testAMissingOutboxDirectoryListsAsEmpty() async throws {
        let outbox = try Outbox(directory: directory)
        try FileManager.default.removeItem(at: directory)
        let entries = try await outbox.list()
        XCTAssertEqual(entries, [])
    }

    // MARK: - Helpers

    private static func lines(mentioning text: String) -> [DebugLogStore.Entry] {
        DebugLogStore.shared.snapshot().filter { $0.category == "SendQueue" && $0.message.contains(text) }
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

/// A `FileManager` whose removals, or directory listings, throw on demand.
/// The listing error carries a token so a test can find its own log line in
/// the process-wide Debug Log. Its state sits behind a `Mutex`, since the
/// outbox calls it from its own executor while the test reads and sets it;
/// hence `@unchecked Sendable`, which Foundation doesn't give `FileManager`.
private final class FailingFileManager: FileManager, @unchecked Sendable {
    private struct State {
        var failRemovals = false
        var listingToken: String?
        var removalAttempts = 0
    }

    private struct InjectedFailure: Error, CustomStringConvertible {
        let description: String
    }

    private let state = Mutex(State())

    var removalAttempts: Int {
        state.withLock { $0.removalAttempts }
    }

    func failRemovals(_ fail: Bool) {
        state.withLock { $0.failRemovals = fail }
    }

    /// Returns the token the listing error carries.
    @discardableResult
    func failListing(_ fail: Bool) -> String {
        let token = "listing-\(UUID().uuidString)"
        state.withLock { $0.listingToken = fail ? token : nil }
        return token
    }

    override func removeItem(at url: URL) throws {
        let fail = state.withLock { state in
            state.removalAttempts += 1
            return state.failRemovals
        }
        if fail { throw InjectedFailure(description: "removal refused") }
        try super.removeItem(at: url)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        if let token = state.withLock({ $0.listingToken }) {
            throw InjectedFailure(description: "listing refused (\(token))")
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
