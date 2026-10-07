import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// `RssSyncEngine`'s single flight: the poller, the Feeds sidebar and the item
/// list ask for syncs at once, and the work is shared rather than repeated.
/// One `syncAll` pass, one sync per feed, one drain plus one more pass for a
/// drain asked for mid-pass; a cancelled caller stops waiting at once, and the
/// work stops once nobody waits for it. Also the pass's report, which keeps
/// catalog, feed and queue failures apart (#1904).
final class RssSyncEngineSingleFlightTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var engine: RssSyncEngine!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-flight-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        client = FakeRssClient()
        await client.set(emptyPagesByDefault: true)
        engine = RssSyncEngine(client: client, store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Subscriptions `s1`... with feeds `f1`... in the server's catalog and the
    /// store, each already populated, so a feed's sync starts with its since-sync.
    private func subscribe(_ count: Int) async throws -> [RssSubscription] {
        let subs = (1...count).map { RssSubscription(subscriptionId: "s\($0)", feedId: "f\($0)") }
        await client.set(catalog: RssCatalog(folders: [], subscriptions: subs))
        try await engine.refreshCatalog()
        for sub in subs {
            try await store.setSyncState(feedId: sub.feedId, .init(sinceCursor: "k"))
        }
        return subs
    }

    private func item(_ number: Int) -> RssItem {
        RssItem(feedId: "f1", itemId: "i\(number)", sortKey: "k\(number)", title: "Item \(number)",
                publishedAt: "2026-01-0\(number)T00:00:00+00:00")
    }

    /// Starts a `syncAll` that parks on the held catalog call, cancels it,
    /// and returns what it returned, failing (rather than hanging) when the
    /// cancelled caller does not stop waiting.
    private func syncAllCancelledWhileHeld() async throws -> RssSyncReport? {
        let (engine, client) = (self.engine!, self.client!)
        let returned = Returned()
        let task = Task { await returned.set(await engine.syncAll()) }
        try await waitUntil { await client.isHolding(.catalog) }
        task.cancel()
        try await waitUntil { await returned.hasReturned }
        return await returned.report
    }

    // MARK: - One pass, shared

    func testOverlappingSyncAllsShareOnePass() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(2)
        let catalogBefore = await client.catalogCalls
        await client.holdNext(.catalog)
        let first = Task { await engine.syncAll() }
        try await waitUntil { await client.isHolding(.catalog) }
        let second = Task { await engine.syncAll() }
        try await waitUntil { await engine.syncAllWaiterCount == 2 }

        await client.release(.catalog)
        let reports = [await first.value, await second.value]

        XCTAssertEqual(reports.map { $0?.subscriptionIds }, [["s1", "s2"], ["s1", "s2"]])
        let catalogCalls = await client.catalogCalls - catalogBefore
        XCTAssertEqual(catalogCalls, 1, "the second caller joined the first pass")
        let synced = await client.syncCalls.map(\.subscriptionId)
        XCTAssertEqual(synced.sorted(), ["s1", "s2"], "each feed synced once")
    }

    func testAScopeSyncJoinsTheFeedSyncAllIsAlreadySyncing() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(1)
        await client.holdNext(.sync("s1"))
        let all = Task { await engine.syncAll() }
        try await waitUntil { await client.isHolding(.sync("s1")) }
        let scope = Task { await engine.syncItems(in: .subscription("s1")) }
        try await waitUntil { await engine.feedSyncWaiterCount("f1") == 2 }

        await client.release(.sync("s1"))
        let allReport = await all.value
        let scopeReport = await scope.value

        XCTAssertEqual(allReport?.feedErrors.isEmpty, true)
        XCTAssertEqual(scopeReport?.subscriptionIds, ["s1"])
        XCTAssertEqual(scopeReport?.feedErrors.isEmpty, true)
        let synced = await client.syncCalls.map(\.subscriptionId)
        XCTAssertEqual(synced, ["s1"], "the list's sync of s1 joined the pass's")
    }

    // MARK: - Cancelled callers

    func testACancelledCallerStopsWaitingWhileTheOthersRunOn() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(1)
        await client.holdNext(.catalog)
        let leaving = Returned()
        let leavingTask = Task { await leaving.set(await engine.syncAll()) }
        try await waitUntil { await client.isHolding(.catalog) }
        let staying = Task { await engine.syncAll() }
        try await waitUntil { await engine.syncAllWaiterCount == 2 }

        leavingTask.cancel()
        try await waitUntil { await leaving.hasReturned }

        let left = await leaving.report
        XCTAssertNil(left, "a cancelled caller gets nothing back")
        let stillHeld = await client.isHolding(.catalog)
        XCTAssertTrue(stillHeld, "it stopped waiting without waiting for the work")
        await client.release(.catalog)
        let stayed = await staying.value
        XCTAssertNotNil(stayed)
        XCTAssertNil(stayed?.catalogError, "the pass was not cancelled while somebody still waited")
        let synced = await client.syncCalls.map(\.subscriptionId)
        XCTAssertEqual(synced, ["s1"])
    }

    func testTheLastCallerLeavingStopsTheWork() async throws {
        let client = self.client!
        _ = try await subscribe(1)
        await client.holdNext(.catalog)
        let only = try await syncAllCancelledWhileHeld()

        await client.release(.catalog)
        try await waitUntil { await client.catalogLog.last == "cancelled" }

        XCTAssertNil(only)
        let synced = await client.syncCalls
        XCTAssertEqual(synced, [], "a pass nobody waits for asks nothing more of the server")
    }

    func testACallerAfterAnAbandonedPassGetsAFreshOneBehindIt() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(1)
        let catalogBefore = await client.catalogCalls
        await client.holdNext(.catalog)
        _ = try await syncAllCancelledWhileHeld()

        // The abandoned pass is still out; the next caller must neither join
        // it (and inherit its cancel) nor run alongside it.
        await client.holdNext(.catalog)
        let next = Task { await engine.syncAll() }
        try await waitUntil { await engine.syncAllWaiterCount == 1 }
        await client.release(.catalog)
        try await waitUntil { await client.isHolding(.catalog) }
        await client.release(.catalog)
        let report = await next.value

        let log = await client.catalogLog.suffix(4)
        XCTAssertEqual(Array(log), ["start", "cancelled", "start", "end"],
                       "the fresh pass started once the abandoned one had ended")
        XCTAssertNotNil(report)
        XCTAssertNil(report?.catalogError)
        let catalogCalls = await client.catalogCalls - catalogBefore
        XCTAssertEqual(catalogCalls, 2)
    }

    func testACallerAlreadyCancelledStartsNothing() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(1)
        let catalogBefore = await client.catalogCalls
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.syncAll()
        }

        let result = await cancelled.value

        XCTAssertNil(result)
        let catalogCalls = await client.catalogCalls - catalogBefore
        XCTAssertEqual(catalogCalls, 0)
    }

    // MARK: - The drain

    func testADrainAskedForMidPassGetsOneMorePass() async throws {
        let (engine, client, store) = (self.engine!, self.client!, self.store!)
        _ = try await subscribe(1)
        try await store.upsertItems([item(1), item(2)])
        try await store.setRead(feedId: "f1", sortKey: "k1", true)
        await client.holdNext(.push)
        let first = Task { try await engine.drainPending() }
        try await waitUntil { await client.isHolding(.push) }

        // Queued after the running pass read the queue.
        try await store.setRead(feedId: "f1", sortKey: "k2", true)
        let second = Task { try await engine.drainPending() }
        let third = Task { try await engine.drainPending() }
        try await waitUntil { await engine.queuedDrainWaiterCount == 2 }
        await client.release(.push)

        let cleared = [try await first.value, try await second.value, try await third.value]
        XCTAssertEqual(cleared, [1, 1, 1], "the two late callers shared one more pass")
        let pushed = await client.stateCalls.map { $0.map(\.sortKey) }
        XCTAssertEqual(pushed, [["k1"], ["k2"]])
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 0, "the mark queued mid-pass went too")
    }

    func testOverlappingDrainsPushARowOnce() async throws {
        let (engine, client, store) = (self.engine!, self.client!, self.store!)
        _ = try await subscribe(1)
        try await store.upsertItems([item(1)])
        try await store.setRead(feedId: "f1", sortKey: "k1", true)

        async let first = engine.drainPending()
        async let second = engine.drainPending()
        _ = try await [first, second]

        let pushes = await client.stateCalls.count
        XCTAssertEqual(pushes, 1, "one row, one push, however many asked")
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Scope syncs

    func testAScopeSyncTriesEveryFeedAndStillDrains() async throws {
        let (engine, client, store) = (self.engine!, self.client!, self.store!)
        _ = try await subscribe(6)
        await client.set(syncError: CabalmailError.transport("offline"), for: "s1")
        for number in 2...4 { await client.holdNext(.sync("s\(number)")) }
        try await store.upsertItems([item(1)])
        try await store.setRead(feedId: "f1", sortKey: "k1", true)

        let scope = Task { await engine.syncItems(in: .all) }
        // s1 fails while s2-s4 are out; the slot it frees goes to s5.
        try await waitUntil { await client.syncCalls.contains { $0.subscriptionId == "s5" } }
        for number in 2...4 { await client.release(.sync("s\(number)")) }
        let reported = await scope.value
        let report = try XCTUnwrap(reported)

        XCTAssertEqual(report.subscriptionIds, ["s1", "s2", "s3", "s4", "s5", "s6"])
        XCTAssertEqual(Array(report.feedErrors.keys), ["s1"])
        XCTAssertFalse(report.everyFeedFailed)
        let synced = await client.syncCalls.map(\.subscriptionId)
        XCTAssertEqual(synced.sorted(), ["s1", "s2", "s3", "s4", "s5", "s6"], "a failed feed doesn't stop the rest")
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 0, "the queue drained after a feed failed")
    }

    func testAScopeSyncRunsFourFeedsAtATime() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(6)
        for number in 1...6 { await client.holdNext(.sync("s\(number)")) }
        let scope = Task { await engine.syncItems(in: .all) }
        try await waitUntil { await client.syncCalls.count == 4 }
        try await Task.sleep(nanoseconds: 50_000_000)

        let started = await client.syncCalls.count
        XCTAssertEqual(started, 4, "no fifth feed until one of the four finishes")
        for number in 1...6 {
            try await waitUntil { await client.isHolding(.sync("s\(number)")) }
            await client.release(.sync("s\(number)"))
        }
        let report = await scope.value
        XCTAssertEqual(report?.feedErrors.isEmpty, true)
        let most = await client.mostSyncsInFlight
        XCTAssertEqual(most, 4)
    }

    // MARK: - The report keeps failures apart (#1904)

    func testACatalogFailureIsNotAFeedFailure() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(2)
        await client.set(catalogError: CabalmailError.transport("offline"))

        let reported = await engine.syncAll()
        let report = try XCTUnwrap(reported)

        XCTAssertNotNil(report.catalogError)
        XCTAssertEqual(report.subscriptionIds, [])
        XCTAssertTrue(report.feedErrors.isEmpty)
        XCTAssertFalse(report.everyFeedFailed)
        let synced = await client.syncCalls
        XCTAssertEqual(synced, [], "nothing past a failed catalog")
    }

    func testAQueueFailureIsNotAFeedFailure() async throws {
        let (engine, client, store) = (self.engine!, self.client!, self.store!)
        _ = try await subscribe(2)
        await client.set(syncError: CabalmailError.transport("offline"), for: "s1")
        try await store.upsertItems([item(1)])
        try await store.setRead(feedId: "f1", sortKey: "k1", true)
        await client.set(failNextState: true)

        let reported = await engine.syncAll()
        let report = try XCTUnwrap(reported)

        XCTAssertNil(report.catalogError)
        XCTAssertNotNil(report.pendingError)
        XCTAssertEqual(Array(report.feedErrors.keys), ["s1"])
        XCTAssertFalse(report.everyFeedFailed, "one feed of two failed; the queue is not a feed")
        XCTAssertEqual(report.firstFeedError as? CabalmailError, .transport("offline"))
    }

    func testEveryFeedFailingIsReportedAsSuch() async throws {
        let (engine, client) = (self.engine!, self.client!)
        _ = try await subscribe(2)
        await client.set(syncError: CabalmailError.transport("offline"), for: "s1")
        await client.set(syncError: CabalmailError.transport("timed out"), for: "s2")

        let reported = await engine.syncAll()
        let report = try XCTUnwrap(reported)

        XCTAssertTrue(report.everyFeedFailed)
        XCTAssertEqual(report.firstFeedError as? CabalmailError, .transport("offline"),
                       "the first feed in store order, not whichever the dictionary yields")
    }
}

/// What a `syncAll` in a task returned, readable without awaiting the task,
/// so a test can wait for it with a timeout.
private actor Returned {
    private(set) var hasReturned = false
    private(set) var report: RssSyncReport?

    func set(_ report: RssSyncReport?) {
        self.report = report
        hasReturned = true
    }
}
