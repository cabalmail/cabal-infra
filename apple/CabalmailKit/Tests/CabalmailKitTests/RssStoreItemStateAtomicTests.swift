import XCTest
@testable import CabalmailKit

/// Marking one item read or favorite is one transaction with the push it
/// queues (#1956), the way mark-all-read already was (#1939). The flag
/// update and the queue's delete-then-insert used to commit separately, so
/// a failure between them left the item changed here with nothing queued —
/// the state sync only delivers rows the server changed, so the device
/// stayed read while the server stayed unread — or, when the delete failed,
/// left an older opposite change queued to be pushed over the user's tap.
final class RssStoreItemStateAtomicTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-itemstate-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        try await store.upsertItems([
            RssItem(feedId: "f1", itemId: "a", sortKey: "a", publishedAt: "2026-01-02T00:00:00Z"),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The queue refuses the push, as a full or busy database would.
    private func refusePushes() async throws {
        try await store.execForTests("""
            CREATE TRIGGER refuse_push BEFORE INSERT ON pending
            BEGIN SELECT RAISE(ABORT, 'database is full'); END
            """)
    }

    func testAFailedReadPushLeavesTheItemUnread() async throws {
        try await refusePushes()

        do {
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            XCTFail("the refused push should fail the mark")
        } catch {}

        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isRead, false, "no local read without its push")
        let queued = try await store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    func testAFailedFavoritePushLeavesTheItemUnfavorited() async throws {
        try await refusePushes()

        do {
            try await store.setFavorite(feedId: "f1", sortKey: "a", true)
            XCTFail("the refused push should fail the favorite")
        } catch {}

        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isFavorite, false, "no local favorite without its push")
        let queued = try await store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    /// The second shape: the queue's delete is in the transaction too, so a
    /// failure there cannot leave the local flag at the new value with the
    /// superseded one still queued to be pushed back over it.
    func testAFailedSupersedeLeavesTheFlagAndTheQueueAgreeing() async throws {
        try await store.setRead(feedId: "f1", sortKey: "a", false)
        try await store.execForTests("""
            CREATE TRIGGER refuse_supersede BEFORE DELETE ON pending
            BEGIN SELECT RAISE(ABORT, 'database is full'); END
            """)

        do {
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            XCTFail("the refused supersede should fail the mark")
        } catch {}

        let item = try await store.item(feedId: "f1", sortKey: "a")
        let queued = try await store.pendingMutations().filter { $0.kind == .read }
        XCTAssertEqual(queued.map(\.value), [false], "the queued change is the one that was there")
        XCTAssertEqual(item?.isRead, queued.first?.value,
                       "the flag the device shows is the one the queue would push")
    }

    /// The control: when it can, the path does both halves.
    func testAReadAndAFavoriteFlipTheItemAndQueueThePush() async throws {
        try await store.setRead(feedId: "f1", sortKey: "a", true)
        try await store.setFavorite(feedId: "f1", sortKey: "a", true)

        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isRead, true)
        XCTAssertEqual(item?.isFavorite, true)
        let queued = try await store.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.read, .favorite])
        XCTAssertEqual(queued.map(\.value), [true, true])
    }
}

private extension RssStore {
    /// Raw SQL against the store's file, for setting up a failure.
    func execForTests(_ sql: String) throws {
        try database.exec(sql)
    }
}
