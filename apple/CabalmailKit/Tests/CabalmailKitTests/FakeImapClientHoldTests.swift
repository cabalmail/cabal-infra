import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// The hold `FakeImapClient` lets a test put on a wire call (`CallGate`).
/// Some sixty suites order their races with it, so each rule is pinned here
/// on its own: a suite that hangs because the hold changed says little about
/// which rule went.
///
/// Every wait is bounded, so a broken rule fails its test instead of hanging
/// the run.
final class FakeImapClientHoldTests: XCTestCase {
    private let imap = FakeImapClient()

    /// Set when a started call has answered, or a waiter has been woken.
    private actor Signal {
        private(set) var fired = false
        func fire() { fired = true }
    }

    private struct Started<Value: Sendable> {
        let task: Task<Value, Error>
        let done: Signal
    }

    /// Runs `call` in a task of its own and signals when it has returned.
    private func start<Value: Sendable>(
        _ call: @escaping @Sendable (FakeImapClient) async throws -> Value
    ) -> Started<Value> {
        let done = Signal()
        let task = Task { [imap] in
            let value = try await call(imap)
            await done.fire()
            return value
        }
        return Started(task: task, done: done)
    }

    private func startStatus() -> Started<FolderStatus> {
        start { try await $0.status(path: "INBOX", flagged: false) }
    }

    /// The call's answer; throws rather than waits when it never comes.
    private func answer<Value: Sendable>(
        of call: Started<Value>, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Value {
        try await waitUntil(file: file, line: line) { await call.done.fired }
        guard await call.done.fired else { throw CabalmailError.cancelled }
        return try await call.task.value
    }

    /// Whether `signal` is still unfired after a short wait: the only way to
    /// see that a parked call has not answered.
    private func staysUnfired(_ signal: Signal) async throws -> Bool {
        try await Task.sleep(nanoseconds: 50_000_000)
        return await !signal.fired
    }

    private func search(_ marker: Int) -> SearchResult {
        SearchResult(envelopes: [], totalEstimate: marker, nextCursor: nil, foldersSearched: [], truncated: false)
    }

    // MARK: A wire call

    func testAHeldCallParksUntilReleasedAndAnswersWithWhatIsScriptedByThen() async throws {
        await imap.holdNext(.status)
        let call = startStatus()
        try await waitUntil { await self.imap.statusCalls.count == 1 }
        let parked = try await staysUnfired(call.done)
        XCTAssertTrue(parked, "a held call answered before it was released")

        // Scripted only now, after the call arrived.
        await imap.scriptStatusResults([.success(FolderStatus(messages: 7))])
        await imap.releaseHeld(.status)

        let status = try await answer(of: call)
        XCTAssertEqual(status.messages, 7)
    }

    func testAHoldCoversOneCall() async throws {
        await imap.scriptStatusResults([.success(FolderStatus(messages: 1)), .success(FolderStatus(messages: 2))])
        await imap.holdNext(.status)
        let first = startStatus()
        try await waitUntil { await self.imap.statusCalls.count == 1 }
        await imap.releaseHeld(.status)
        let firstStatus = try await answer(of: first)
        XCTAssertEqual(firstStatus.messages, 1)

        let second = try await answer(of: startStatus())
        XCTAssertEqual(second.messages, 2, "the call after a held one passes without a release")
    }

    func testAHoldIsForOneKindOfCall() async throws {
        await imap.scriptStatusResults([.success(FolderStatus(messages: 3))])
        await imap.holdNext(.move)
        await imap.holdNextSearch()

        let status = try await answer(of: startStatus())
        XCTAssertEqual(status.messages, 3, "a hold on a move or a search does not park a STATUS")
    }

    func testAwaitHeldReturnsAtOnceForACallAlreadyParked() async throws {
        await imap.holdNext(.status)
        let call = startStatus()
        try await waitUntil { await self.imap.statusCalls.count == 1 }

        let arrived = Signal()
        let waiter = Task { [imap] in
            await imap.awaitHeld(.status)
            await arrived.fire()
        }
        try await waitUntil { await arrived.fired }

        waiter.cancel()
        await imap.scriptStatusResults([.success(FolderStatus())])
        await imap.releaseHeld(.status)
        _ = try await answer(of: call)
    }

    func testAwaitHeldWaitsForACallThatHasNotArrived() async throws {
        await imap.holdNext(.move)
        let arrived = Signal()
        let waiter = Task { [imap] in
            await imap.awaitHeld(.move)
            await arrived.fire()
        }
        let waiting = try await staysUnfired(arrived)
        XCTAssertTrue(waiting, "awaitHeld returned before any move was made")

        let call = start { try await $0.move(folder: "INBOX", uids: [1], destination: "Archive", markSeen: false) }
        try await waitUntil { await arrived.fired }

        waiter.cancel()
        await imap.releaseHeld(.move)
        try await answer(of: call)
    }

    func testReleasingBeforeTheCallArrivesKeepsTheHold() async throws {
        await imap.holdNext(.purge)
        await imap.releaseHeld(.purge)

        let call = start { try await $0.purge(folder: "Trash", uids: [1]) }
        try await waitUntil { await self.imap.purgeCalls.count == 1 }
        let parked = try await staysUnfired(call.done)
        XCTAssertTrue(parked, "a release with nothing parked spent the hold")

        await imap.releaseHeld(.purge)
        try await answer(of: call)
    }

    // MARK: A search

    func testAHeldSearchParksUntilReleased() async throws {
        await imap.holdNextSearch()
        let call = start { try await $0.searchEnvelopes(SearchQuery(text: "invoice")) }

        let arrived = Signal()
        let waiter = Task { [imap] in
            await imap.awaitHeldSearch()
            await arrived.fire()
        }
        try await waitUntil { await arrived.fired }
        let parked = try await staysUnfired(call.done)
        XCTAssertTrue(parked, "a held search answered before it was released")

        waiter.cancel()
        await imap.scriptSearch(search(4))
        await imap.releaseHeldSearch()

        let result = try await answer(of: call)
        XCTAssertEqual(result.totalEstimate, 4)
    }

    func testReleasingAHeldSearchBeforeItArrivesDropsTheHold() async throws {
        await imap.scriptSearch(search(5))
        await imap.holdNextSearch()
        await imap.releaseHeldSearch()

        let result = try await answer(of: start { try await $0.searchEnvelopes(SearchQuery(text: "invoice")) })
        XCTAssertEqual(result.totalEstimate, 5, "unlike a wire call's, a search's release also drops an untaken hold")
    }
}
