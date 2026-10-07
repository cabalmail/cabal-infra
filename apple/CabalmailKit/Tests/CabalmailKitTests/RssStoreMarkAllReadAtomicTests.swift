import XCTest
@testable import CabalmailKit

/// Mark-all-read is one transaction with the push it queues (#1939). Its
/// three writes used to run separately, so a failure after the first left
/// the local read watermark advanced with no push queued: the device then
/// showed the feed read while the server and other devices showed it
/// unread, and nothing reconciled it, since the store keeps the higher of
/// its own and the server's watermark.
final class RssStoreMarkAllReadAtomicTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-markall-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1",
                                                           readWatermark: "2026-01-01T00:00:00Z"))
        try await store.upsertItems([
            RssItem(feedId: "f1", itemId: "a", sortKey: "a", publishedAt: "2026-01-02T00:00:00Z"),
        ])
        try await store.setRead(feedId: "f1", sortKey: "a", false)
        try await store.deletePending(ids: try await store.pendingMutations().map(\.id))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAFailedMarkAllReadLeavesTheFeedAsItWas() async throws {
        // The queue refuses the push, as a full or busy database would.
        try await store.execForTests("""
            CREATE TRIGGER refuse_push BEFORE INSERT ON pending
            BEGIN SELECT RAISE(ABORT, 'database is full'); END
            """)

        do {
            try await store.markAllRead(subscriptionId: "s1", watermark: "2026-01-05T00:00:00Z")
            XCTFail("the refused push should fail the mark")
        } catch {}

        let watermark = try await store.subscription(id: "s1")?.readWatermark
        XCTAssertEqual(watermark, "2026-01-01T00:00:00Z", "no watermark without its push")
        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isRead, false, "the explicit unread stands")
        let queued = try await store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    /// The control: a mark that succeeds does all three.
    func testAMarkAllReadAdvancesFlipsAndQueuesTogether() async throws {
        try await store.markAllRead(subscriptionId: "s1", watermark: "2026-01-05T00:00:00Z")

        let watermark = try await store.subscription(id: "s1")?.readWatermark
        XCTAssertEqual(watermark, "2026-01-05T00:00:00Z")
        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isRead, true)
        let queued = try await store.pendingMutations().map(\.kind)
        XCTAssertEqual(queued, [.markAllRead])
    }
}

private extension RssStore {
    /// Raw SQL against the store's file, for setting up a failure.
    func execForTests(_ sql: String) throws {
        try database.exec(sql)
    }
}
