import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// `RssStore.changes()`: each write announced once it commits, saying what it
/// moved: an item's state, a feed's items, the catalog, or everything. The
/// feed views re-read the store from these instead of being told by whoever
/// wrote.
final class RssStoreChangeStreamTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-changes-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: "w1"))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s2", feedId: "f2"))
        try await store.upsertItems([item("k1"), item("k2"), item("k3", feed: "f2")])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ sortKey: String, feed: String = "f1") -> RssItem {
        RssItem(feedId: feed, itemId: sortKey, sortKey: sortKey, publishedAt: "2026-01-01T00:00:00+00:00")
    }

    /// What the stream yields while `write` runs: subscribed first, drained
    /// after, so exactly that write's announcements.
    private func changes(during write: (RssStore) async throws -> Void) async throws -> [RssStore.Change] {
        let store = self.store!
        let stream = await store.changes()
        try await write(store)
        let drain = Task {
            var seen: [RssStore.Change] = []
            for await change in stream { seen.append(change) }
            return seen
        }
        // Cancelling finishes the stream, which still hands over its buffer.
        drain.cancel()
        return await drain.value
    }

    // MARK: - Items

    func testALocalMarkAnnouncesItsItem() async throws {
        let read = try await changes { try await $0.setRead(feedId: "f1", sortKey: "k1", true) }
        let flagged = try await changes { try await $0.setFavorite(feedId: "f1", sortKey: "k2", true) }

        XCTAssertEqual(read, [.items(["f1#k1"])])
        XCTAssertEqual(flagged, [.items(["f1#k2"])])
    }

    func testAPushedQueueRowAnnouncesItsItem() async throws {
        try await store.setRead(feedId: "f1", sortKey: "k1", true)
        try await store.markAllRead(subscriptionId: "s2", watermark: "w2")
        let ids = try await store.pendingMutations().map(\.id)

        let drained = try await changes { try await $0.deletePending(ids: ids) }

        XCTAssertEqual(drained, [.items(["f1#k1"])], "the item loses its queued mark; a mark-all-read row has no item")
    }

    // MARK: - Feeds

    func testSyncWritesAnnounceTheirFeeds() async throws {
        let upserted = try await changes { try await $0.upsertItems([self.item("k4"), self.item("k5", feed: "f2")]) }
        let states = try await changes {
            try await $0.applyServerStates([RssItemState(feedId: "f2", sortKey: "k3", isRead: true)])
        }
        let cursors = try await changes { try await $0.setSyncState(feedId: "f1", .init(sinceCursor: "c")) }
        let watermark = try await changes { try await $0.applyServerWatermark(subscriptionId: "s1", watermark: "w9") }
        let allRead = try await changes { try await $0.markAllRead(subscriptionId: "s2", watermark: "w9") }

        XCTAssertEqual(upserted, [.feeds(["f1", "f2"])])
        XCTAssertEqual(states, [.feeds(["f2"])])
        XCTAssertEqual(cursors, [.feeds(["f1"])])
        XCTAssertEqual(watermark, [.feeds(["f1"])])
        XCTAssertEqual(allRead, [.feeds(["f2"])])
    }

    func testWritesThatChangeNothingAnnounceNothing() async throws {
        let none = try await changes {
            try await $0.upsertItems([])
            try await $0.applyServerStates([])
            try await $0.deletePending(ids: [])
        }

        XCTAssertEqual(none, [])
    }

    // MARK: - Catalog

    func testCatalogWritesAnnounceTheCatalog() async throws {
        let folder = try await changes { try await $0.upsertFolder(RssFolder(folderId: "d1", name: "News")) }
        let subscription = try await changes {
            try await $0.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1", customTitle: "Mine",
                                                            readWatermark: "w1"))
        }
        let catalog = try await changes {
            _ = try await $0.replaceCatalog(RssCatalog(
                folders: [RssFolder(folderId: "d1", name: "News")],
                subscriptions: [
                    RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: "w1"),
                    RssSubscription(subscriptionId: "s2", feedId: "f2"),
                ]
            ))
        }

        XCTAssertEqual(folder, [.catalog])
        XCTAssertEqual(subscription, [.catalog])
        XCTAssertEqual(catalog, [.catalog], "one announcement for the catalog; no read state moved")
    }

    /// Another device's mark-all-read reaches this one as an advanced
    /// watermark on the subscription row, and a departed subscription takes
    /// its items: both move the lists, so the feeds are announced too.
    func testAnAdvancedWatermarkOrADepartedFeedAlsoMovesItsFeed() async throws {
        let replaced = try await changes {
            _ = try await $0.replaceCatalog(RssCatalog(folders: [], subscriptions: [
                RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: "w5"),
            ]))
        }
        let upserted = try await changes {
            try await $0.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: "w7"))
        }

        XCTAssertEqual(replaced, [.catalog, .feeds(["f1", "f2"])])
        XCTAssertEqual(upserted, [.catalog, .feeds(["f1"])])
    }

    func testClearAnnouncesCleared() async throws {
        let cleared = try await changes { try await $0.clear() }

        XCTAssertEqual(cleared, [.cleared])
    }

    // MARK: - Observers

    func testEveryObserverGetsEveryChange() async throws {
        let first = await store.changes()
        let second = await store.changes()

        try await store.setRead(feedId: "f1", sortKey: "k1", true)
        try await store.upsertFolder(RssFolder(folderId: "d1", name: "News"))

        for stream in [first, second] {
            let drain = Task {
                var seen: [RssStore.Change] = []
                for await change in stream { seen.append(change) }
                return seen
            }
            drain.cancel()
            let seen = await drain.value
            XCTAssertEqual(seen, [.items(["f1#k1"]), .catalog])
        }
    }

    func testAConsumerThatStopsIsForgotten() async throws {
        let store = self.store!
        let consumer = Task { for await _ in await store.changes() {} }
        try await waitUntil { await store.hasChangeObservers }

        consumer.cancel()

        try await waitUntil { await !store.hasChangeObservers }
    }

    /// The termination handler holds the store weakly (#1761's rule), so a
    /// live stream doesn't keep a signed-out session's store alive.
    func testTheStoreDeallocatesWhileASubscriberStillHoldsTheStream() async throws {
        var owned: RssStore? = try RssStore(directory: tempDir.appendingPathComponent("second"))
        weak let leaked: RssStore? = owned
        let stream = await owned!.changes()
        owned = nil

        var released = false
        for _ in 0..<200 {
            if leaked == nil {
                released = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(released, "the store outlived its last owner: a subscriber's termination handler holds it")
        withExtendedLifetime(stream) {}
    }

    /// Releasing the store finishes its streams, so a view following a
    /// signed-out session's store stops instead of waiting forever.
    func testReleasingTheStoreFinishesItsStreams() async throws {
        var owned: RssStore? = try RssStore(directory: tempDir.appendingPathComponent("second"))
        let stream = await owned!.changes()
        owned = nil

        let finished = await finishesWithoutCancelling(stream)

        XCTAssertTrue(finished, "the stream outlived its store")
    }
}
