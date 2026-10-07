import XCTest
@testable import CabalmailKit

/// `RssStore.filterCounts(in:)`: what a feed list's All / Unread / Flagged
/// pills count, over the scope's cached items and by the store's read rule
/// (an explicit mark, else the subscription's read watermark).
final class RssStoreFilterCountsTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-counts-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        _ = try await store.replaceCatalog(RssCatalog(
            folders: [RssFolder(folderId: "d", name: "Tech")],
            subscriptions: [
                RssSubscription(subscriptionId: "s1", feedId: "f1", folderId: "d",
                                readWatermark: "2026-01-02T00:00:00Z"),
                RssSubscription(subscriptionId: "s2", feedId: "f2"),
            ]
        ))
        try await store.upsertItems([
            item("a", feed: "f1", day: 1),   // read by the watermark
            item("b", feed: "f1", day: 3),
            item("c", feed: "f1", day: 4),
            item("d", feed: "f2", day: 1),
        ])
        try await store.setRead(feedId: "f1", sortKey: "c", true)
        try await store.setFavorite(feedId: "f1", sortKey: "b", true)
        try await store.setFavorite(feedId: "f2", sortKey: "d", true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ key: String, feed: String, day: Int) -> RssItem {
        RssItem(feedId: feed, itemId: key, sortKey: key, publishedAt: "2026-01-0\(day)T00:00:00Z")
    }

    func testCountsFollowTheScope() async throws {
        let feed = try await store.filterCounts(in: .subscription("s1"))
        let folder = try await store.filterCounts(in: .folder("d"))
        let all = try await store.filterCounts(in: .all)

        XCTAssertEqual(feed, RssStore.FilterCounts(all: 3, unread: 1, favorite: 1))
        XCTAssertEqual(folder, feed, "the folder holds just s1")
        XCTAssertEqual(all, RssStore.FilterCounts(all: 4, unread: 2, favorite: 2))
    }

    /// The pills count what the list shows under each pill.
    func testEachCountMatchesItsPillsRows() async throws {
        for scope in [RssItemScope.subscription("s1"), .folder("d"), .all] {
            let counts = try await store.filterCounts(in: scope)
            for filter in RssItemFilter.allCases {
                let rows = try await store.items(.init(scope: scope, filter: filter, limit: 1000))
                XCTAssertEqual(counts.count(for: filter), rows.count, "\(scope) \(filter)")
            }
        }
    }

    func testAnExplicitUnreadBelowTheWatermarkCounts() async throws {
        try await store.setRead(feedId: "f1", sortKey: "a", false)

        let counts = try await store.filterCounts(in: .subscription("s1"))

        XCTAssertEqual(counts.unread, 2)
    }

    func testAnEmptyScopeCountsNothing() async throws {
        let counts = try await store.filterCounts(in: .folder("missing"))

        XCTAssertEqual(counts, RssStore.FilterCounts())
    }
}
