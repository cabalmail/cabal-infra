import XCTest
@testable import CabalmailKit

final class RssStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-store-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sub(_ id: String, feed: String, folder: String = "", watermark: String = "") -> RssSubscription {
        RssSubscription(subscriptionId: id, feedId: feed, folderId: folder, readWatermark: watermark,
                        dataStoreUuid: "ds-\(id)", feed: RssFeedSummary(feedId: feed, title: feed.uppercased()))
    }

    private func item(_ feed: String, _ day: Int, read: Bool = false, favorite: Bool = false,
                      title: String = "", body: String = "") -> RssItem {
        let pub = String(format: "2026-01-%02dT00:00:00+00:00", day)
        return RssItem(feedId: feed, itemId: "i\(day)", sortKey: "\(pub)#i\(day)",
            title: title.isEmpty ? "Item \(day)" : title,
                       publishedAt: pub, fetchedKey: String(format: "2026-02-01T00:00:%02d+00:00#i%d", day, day),
                       summaryHtml: "<p>\(body.isEmpty ? "body \(day)" : body)</p>", isRead: read, isFavorite: favorite)
    }

    func testCatalogReplaceUpsertsAndRemoves() async throws {
        let first = RssCatalog(folders: [RssFolder(folderId: "fo", name: "Tech")],
                               subscriptions: [sub("s1", feed: "f1", folder: "fo"), sub("s2", feed: "f2")])
        let diff1 = try await store.replaceCatalog(first)
        XCTAssertEqual(diff1.removedSubscriptionIds, [])
        try await store.upsertItems([item("f2", 1)])
        let second = RssCatalog(folders: [], subscriptions: [sub("s1", feed: "f1", watermark: "2026-01-05")])
        let diff2 = try await store.replaceCatalog(second)
        XCTAssertEqual(diff2.removedSubscriptionIds, ["s2"])
        XCTAssertEqual(diff2.removedDataStoreUuids, ["ds-s2"])
        XCTAssertEqual(diff2.removedFeedIds, ["f2"])
        let subs = try await store.subscriptions()
        XCTAssertEqual(subs.map(\.subscriptionId), ["s1"])
        XCTAssertEqual(subs[0].folderId, "")
        XCTAssertEqual(subs[0].readWatermark, "2026-01-05")
        XCTAssertEqual(subs[0].feed?.title, "F1")
        let observed1 = try await store.folders()
        XCTAssertEqual(observed1, [])
        let observed2 = try await store.itemCount(feedId: "f2")
        XCTAssertEqual(observed2, 0)
    }

    func testReadStateRuleWatermarkAndExplicit() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [],
            subscriptions: [sub("s1", feed: "f1", watermark: "2026-01-03T00:00:00+00:00")]))
        try await store.upsertItems([item("f1", 1), item("f1",
            2), item("f1", 3), item("f1", 4), item("f1", 5, read: true)])
        var unread = try await store.items(.init(scope: .subscription("s1"), filter: .unread))
        XCTAssertEqual(unread.map(\.itemId), ["i4"])            // 1-3 under the watermark, 5 read server-side
        try await store.setRead(feedId: "f1", sortKey: item("f1", 2).sortKey, false)   // explicit unread wins
        try await store.setRead(feedId: "f1", sortKey: item("f1", 4).sortKey, true)
        unread = try await store.items(.init(scope: .subscription("s1"), filter: .unread))
        XCTAssertEqual(unread.map(\.itemId), ["i2"])
        let observed3 = try await store.unreadCounts()
        XCTAssertEqual(observed3, ["s1": 1])
        let all = try await store.items(.init(scope: .subscription("s1"), filter: .all, ordering: .oldestFirst))
        XCTAssertEqual(all.map(\.itemId), ["i1", "i2", "i3", "i4", "i5"])
        XCTAssertEqual(all.map(\.isRead), [true, false, true, true, true])
        XCTAssertEqual(all[0].subscriptionId, "s1")
    }

    func testServerExplicitUnreadSurvivesTheLocalWatermark() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [],
            subscriptions: [sub("s1", feed: "f1", watermark: "2026-01-03T00:00:00+00:00")]))
        // Item 1 is older than the watermark but the server says the user
        // marked it unread by hand; that mark must not read as read here.
        var unread = item("f1", 1)
        unread.isReadExplicit = true
        try await store.upsertItems([unread, item("f1", 2)])
        let rows = try await store.items(.init(scope: .all, ordering: .oldestFirst))
        XCTAssertEqual(rows.map(\.isRead), [false, true])
        XCTAssertEqual(rows.map(\.isReadExplicit), [true, false])
        // Re-listed without the marker (say, after the user marked it read
        // elsewhere), the watermark rule applies again.
        try await store.upsertItems([item("f1", 1)])
        let observed8 = try await store.items(.init(scope: .all, ordering: .oldestFirst))[0].isRead
        XCTAssertTrue(observed8)
    }

    func testServerUpsertKeepsLocalStateWhilePending() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [sub("s1", feed: "f1")]))
        try await store.upsertItems([item("f1", 1), item("f1", 2)])
        try await store.setFavorite(feedId: "f1", sortKey: item("f1", 1).sortKey, true)
        try await store.setRead(feedId: "f1", sortKey: item("f1", 1).sortKey, true)
        // Server copy arrives stale (not read, not favorite) while the push is pending.
        try await store.upsertItems([item("f1", 1, title: "Retitled"), item("f1", 2, read: true)])
        let rows = try await store.items(.init(scope: .all, ordering: .oldestFirst))
        XCTAssertEqual(rows[0].title, "Retitled")
        XCTAssertTrue(rows[0].isRead)
        XCTAssertTrue(rows[0].isFavorite)
        XCTAssertTrue(rows[1].isRead)                          // no pending: server wins
        let pending = try await store.pendingMutations()
        XCTAssertEqual(pending.map(\.kind), [.favorite, .read])
        try await store.deletePending(ids: pending.map(\.id))
        // With nothing pending the next server copy wins.
        try await store.upsertItems([item("f1", 1)])
        let observed4 = try await store.items(.init(scope: .all, ordering: .oldestFirst))[0].isRead
        XCTAssertFalse(observed4)
    }

    func testMarkAllReadFlipsExplicitUnreadAndQueues() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [sub("s1", feed: "f1")]))
        try await store.upsertItems([item("f1", 1), item("f1", 2)])
        try await store.setRead(feedId: "f1", sortKey: item("f1", 1).sortKey, false)
        try await store.markAllRead(subscriptionId: "s1", watermark: "2026-12-31T00:00:00+00:00")
        let observed5 = try await store.unreadCounts()
        XCTAssertEqual(observed5, [:])
        let observed6 = try await store.subscription(id: "s1")?.readWatermark
        XCTAssertEqual(observed6, "2026-12-31T00:00:00+00:00")
        let observed7 = try await store.pendingMutations().map(\.kind)
        XCTAssertEqual(observed7, [.read, .markAllRead])
    }

    func testFolderScopeIncludesDescendantsAndOrderings() async throws {
        let folders = [RssFolder(folderId: "top", name: "Top"),
            RssFolder(folderId: "kid", parentFolderId: "top", name: "Kid")]
        _ = try await store.replaceCatalog(RssCatalog(folders: folders, subscriptions: [
            sub("s1", feed: "f1", folder: "kid"), sub("s2", feed: "f2", folder: "top"), sub("s3", feed: "f3")]))
        try await store.upsertItems([item("f1", 1), item("f2", 2), item("f3", 3)])
        let observed8 = try await store.items(.init(scope: .folder("top"))).map(\.feedId)
        XCTAssertEqual(observed8, ["f2", "f1"])
        let observed9 = try await store.items(.init(scope: .folder("kid"))).map(\.feedId)
        XCTAssertEqual(observed9, ["f1"])
        let observed10 = try await store.items(.init(scope: .all)).count
        XCTAssertEqual(observed10, 3)
        // Day-grouped ordering: newest day first, oldest within the day.
        try await store.upsertItems([
            RssItem(feedId: "f3", itemId: "a", sortKey: "2026-03-01T08:00:00+00:00#a",
                publishedAt: "2026-03-01T08:00:00+00:00"),
            RssItem(feedId: "f3", itemId: "b", sortKey: "2026-03-01T20:00:00+00:00#b",
                publishedAt: "2026-03-01T20:00:00+00:00"),
        ])
        let grouped = try await store.items(.init(scope: .subscription("s3"), ordering: .newestDayOldestWithin))
        XCTAssertEqual(grouped.map(\.itemId), ["a", "b", "i3"])
    }

    func testFullTextSearchPerFeed() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [],
            subscriptions: [sub("s1", feed: "f1"), sub("s2", feed: "f2")]))
        try await store.upsertItems([
            item("f1", 1, title: "Swift concurrency", body: "actors and <b>isolation</b>"),
            item("f1", 2, title: "Cooking", body: "isolated recipes"),
            item("f2", 3, title: "Swift birds", body: "migration"),
        ])
        let observed11 = try await store.search(feedId: "f1", query: "swift").map(\.itemId)
        XCTAssertEqual(observed11, ["i1"])
        let observed101 = Set(try await store.search(feedId: "f1", query: "isolat").map(\.itemId))
        XCTAssertEqual(observed101, ["i1", "i2"])
        let observed12 = try await store.search(feedId: "f1", query: "actor recipe").map(\.itemId)
        XCTAssertEqual(observed12, [])
        let observed13 = try await store.search(feedId: "f1", query: "  \"  ").map(\.itemId)
        XCTAssertEqual(observed13, [])
        XCTAssertEqual(RssStore.ftsQuery("hello NOT world"), "\"hello\"* \"NOT\"* \"world\"*")
    }

    func testSyncStateRoundTrip() async throws {
        let observed14 = try await store.syncState(feedId: "f1")
        XCTAssertEqual(observed14, RssStore.FeedSyncState())
        try await store.setSyncState(feedId: "f1", .init(sinceCursor: "k",
            olderCursor: "c", olderExhausted: true, lastSyncedAt: "t", stateCursor: "sc"))
        let observed15 = try await store.syncState(feedId: "f1")
        XCTAssertEqual(observed15, .init(sinceCursor: "k", olderCursor: "c", olderExhausted: true,
                                         lastSyncedAt: "t", stateCursor: "sc"))
    }
}
