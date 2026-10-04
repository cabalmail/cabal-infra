import XCTest
@testable import CabalmailKit

/// Keyset paging over `RssStore.items`: the next page is what sorts after
/// the last row shown, so a result set that changes between pages (items
/// read in the Unread pill, newer items synced in) neither skips nor
/// repeats rows.
final class RssStorePagingTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-paging-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [
            RssSubscription(subscriptionId: "s1", feedId: "f1"), RssSubscription(subscriptionId: "s2", feedId: "f2"),
        ]))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ feed: String, day: Int, hour: Int = 0, id: String? = nil) -> RssItem {
        let pub = String(format: "2026-01-%02dT%02d:00:00+00:00", day, hour)
        let itemId = id ?? "i\(day)"
        return RssItem(feedId: feed, itemId: itemId, sortKey: "\(pub)#\(itemId)", publishedAt: pub)
    }

    private func page(_ filter: RssItemFilter = .all, ordering: RssOrderingMode = .newestFirst,
                      after: RssItem? = nil, limit: Int = 2) async throws -> [RssItem] {
        try await store.items(.init(scope: .all, filter: filter, ordering: ordering, limit: limit,
                                    after: after.map(RssStore.ItemCursor.init(after:))))
    }

    /// Reading the rows on page one (which stay on screen) shrinks the
    /// Unread set; an offset would then step past unread items.
    func testUnreadPagingSurvivesReadsBetweenPages() async throws {
        try await store.upsertItems((1...5).map { item("f1", day: $0) })
        let first = try await page(.unread)
        XCTAssertEqual(first.map(\.itemId), ["i5", "i4"])
        for row in first { try await store.setRead(feedId: row.feedId, sortKey: row.sortKey, true) }
        let second = try await page(.unread, after: first.last)
        XCTAssertEqual(second.map(\.itemId), ["i3", "i2"])
        let third = try await page(.unread, after: second.last)
        XCTAssertEqual(third.map(\.itemId), ["i1"])
    }

    /// Newer items synced in after page one sort above it; an offset would
    /// re-return rows already shown.
    func testPagingSurvivesInsertsBetweenPages() async throws {
        try await store.upsertItems((1...5).map { item("f1", day: $0) })
        let first = try await page()
        XCTAssertEqual(first.map(\.itemId), ["i5", "i4"])
        try await store.upsertItems([item("f1", day: 6), item("f2", day: 7)])
        let second = try await page(after: first.last)
        XCTAssertEqual(second.map(\.itemId), ["i3", "i2"])
    }

    /// Every ordering, paged one row at a time, visits exactly the rows of
    /// one unpaged read in the same order - including the day-grouped
    /// orders across a day boundary and two feeds with the same sort key.
    func testOneRowPagesMatchTheFullListingInEveryOrdering() async throws {
        try await store.upsertItems([
            item("f1", day: 1, hour: 8), item("f1", day: 1, hour: 20, id: "late"), item("f1", day: 2),
            item("f2", day: 2), item("f2", day: 3, hour: 5),
        ])
        let orderings: [RssOrderingMode] = [.newestFirst, .oldestFirst, .newestDayOldestWithin, .oldestDayNewestWithin]
        for ordering in orderings {
            let full = try await page(ordering: ordering, limit: 100)
            XCTAssertEqual(full.count, 5)
            var walked: [RssItem] = []
            while true {
                let next = try await page(ordering: ordering, after: walked.last, limit: 1)
                guard let row = next.first else { break }
                walked.append(row)
                XCTAssertLessThanOrEqual(walked.count, 5, "\(ordering) never terminates")
                if walked.count > 5 { break }
            }
            XCTAssertEqual(walked.map(\.id), full.map(\.id), "\(ordering)")
        }
    }
}
