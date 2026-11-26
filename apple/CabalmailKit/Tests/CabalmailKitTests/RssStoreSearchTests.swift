import XCTest
@testable import CabalmailKit

/// `RssStore`'s search of every feed (`search(_:limit:after:)`,
/// `searchCount`): what the app's search lists as its feed results.
///
/// Two subscribed feeds, and one item of a feed nobody subscribes to.
final class RssStoreSearchTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-search-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        _ = try await store.replaceCatalog(RssCatalog(
            folders: [],
            subscriptions: [
                // Everything published up to the 3rd counts as read here.
                RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: "2026-01-03T23:59:59Z"),
                RssSubscription(subscriptionId: "s2", feedId: "f2"),
            ]
        ))
        try await store.upsertItems([
            item("a", feed: "f1", day: 1, title: "Harbour lights", body: "the <b>ferry</b> timetable"),
            item("b", feed: "f2", day: 2, title: "Ferry strike ends", body: "crews return"),
            item("c", feed: "f1", day: 3, title: "Cooking", body: "a ferryman's stew"),
            item("d", feed: "f2", day: 4, title: "Harbour dredging", body: "silt and ferry lanes", favorite: true),
            item("e", feed: "f1", day: 5, title: "Weather", body: "calm seas", flags: ["cabal-flag-03"]),
            // Items can land for a feed after its subscription has gone.
            item("f", feed: "gone", day: 6, title: "Ferry museum", body: "an unsubscribed feed's item"),
            RssItem(feedId: "f2", itemId: "undated", sortKey: "0000#undated", title: "Ferry archive"),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(
        _ key: String, feed: String, day: Int, title: String, body: String, favorite: Bool = false,
        flags: Set<String> = []
    ) -> RssItem {
        let published = "2026-01-0\(day)T12:00:00Z"
        return RssItem(
            feedId: feed, itemId: key, sortKey: "\(published)#\(key)", title: title, publishedAt: published,
            contentHtml: "<p>\(body)</p>", isFavorite: favorite, flags: flags
        )
    }

    private func day(_ day: Int, hour: Int = 12) -> Date {
        ISO8601DateFormatter().date(from: String(format: "2026-01-%02dT%02d:00:00Z", day, hour)) ?? Date()
    }

    private func found(_ search: RssStore.ItemSearch) async throws -> [String] {
        try await store.search(search, limit: 100).map(\.itemId)
    }

    // MARK: The words

    func testAWordIsFoundInEveryFeedNewestFirst() async throws {
        let ferry = try await found(.init(text: "ferry"))

        XCTAssertEqual(ferry, ["d", "c", "b", "a", "undated"],
                       "title and body, both feeds, a prefix of a longer word, newest first")
    }

    func testAnItemOfAFeedWithNoSubscriptionIsNotFound() async throws {
        let cached = try await store.item(feedId: "gone", sortKey: "2026-01-06T12:00:00Z#f")
        XCTAssertNotNil(cached, "the item is still in the store, so only the search's own rule keeps it out")

        let museum = try await found(.init(text: "museum"))
        let count = try await store.searchCount(.init(text: "museum"))

        XCTAssertEqual(museum, [])
        XCTAssertEqual(count, 0)
    }

    func testEveryWordIsRequired() async throws {
        let both = try await found(.init(text: "harbour ferr"))
        let neither = try await found(.init(text: "harbour stew"))

        XCTAssertEqual(both, ["d", "a"])
        XCTAssertEqual(neither, [])
    }

    func testTextThatIsNoWordSearchesNothing() async throws {
        let quotes = try await found(.init(text: "  \"  "))
        let count = try await store.searchCount(.init(text: "  \"  "))

        XCTAssertEqual(quotes, [])
        XCTAssertEqual(count, 0)
        XCTAssertFalse(RssStore.ItemSearch(text: "  \"  ").hasPredicate)
    }

    func testASearchWithNothingToMatchOnFindsNothing() async throws {
        let nothing = try await found(.init())
        let count = try await store.searchCount(.init())

        XCTAssertEqual(nothing, [], "not every cached item: that is a feed list, not a search")
        XCTAssertEqual(count, 0)
    }

    // MARK: The filters

    func testUnreadFollowsTheStoresReadRule() async throws {
        // In f1 the watermark has read everything up to the 3rd; f2 has
        // none, so its dated items are unread until marked. An item with no
        // date is never past a watermark, which the store counts as read.
        try await store.setRead(feedId: "f2", sortKey: "2026-01-02T12:00:00Z#b", true)

        let unread = try await found(.init(text: "ferry", unread: true))

        XCTAssertEqual(unread, ["d"], "not a or c (the watermark) nor b (marked read)")
    }

    func testAFlagNarrowsByTheListsCriterion() async throws {
        let builtIn = try await found(.init(text: "ferr", flag: .slot(FlagPalette.systemSlot)))
        let any = try await found(.init(flag: .any))
        let custom = try await found(.init(flag: .slot("cabal-flag-03")))

        XCTAssertEqual(builtIn, ["d"])
        XCTAssertEqual(any, ["e", "d"], "no words: the filters alone select")
        XCTAssertEqual(custom, ["e"])
    }

    func testSinceIncludesItsDayAndBeforeExcludesIts() async throws {
        let since = try await found(.init(text: "ferry", since: day(3, hour: 23)))
        let before = try await found(.init(text: "ferry", before: day(3, hour: 1)))
        let between = try await found(.init(text: "ferry", since: day(2), before: day(4)))

        XCTAssertEqual(since, ["d", "c"], "the 3rd is included whatever the hour asked with")
        XCTAssertEqual(before, ["b", "a"], "the 3rd is not, and neither is the item with no date")
        XCTAssertEqual(between, ["c", "b"])
    }

    func testADayIsReadInUTC() {
        let lateOnTheSecond = ISO8601DateFormatter().date(from: "2026-01-02T23:30:00-05:00") ?? Date()

        XCTAssertEqual(RssStore.utcDay(lateOnTheSecond), "2026-01-03")
    }

    // MARK: Pages and the count

    func testPagesNeitherSkipNorRepeatARow() async throws {
        let search = RssStore.ItemSearch(text: "ferry")
        var listed: [String] = []
        var cursor: RssStore.ItemCursor?
        for _ in 0..<5 {
            let page = try await store.search(search, limit: 2, after: cursor)
            listed += page.map(\.itemId)
            guard let last = page.last, page.count == 2 else { break }
            cursor = RssStore.ItemCursor(after: last)
        }

        XCTAssertEqual(listed, ["d", "c", "b", "a", "undated"])
    }

    func testAMarkBetweenTwoPagesLosesNoRow() async throws {
        let search = RssStore.ItemSearch(text: "ferry", unread: true)
        try await store.upsertItems([
            item("g", feed: "f2", day: 7, title: "Ferry fares", body: "up again"),
            item("h", feed: "f2", day: 8, title: "Ferry queue", body: "long"),
        ])
        let first = try await store.search(search, limit: 2)
        XCTAssertEqual(first.map(\.itemId), ["h", "g"])

        // The first page's rows are read, so they no longer match: a page
        // found by position would now start two rows too far on.
        for row in first { try await store.setRead(feedId: row.feedId, sortKey: row.sortKey, true) }
        let second = try await store.search(search, limit: 2, after: first.last.map(RssStore.ItemCursor.init(after:)))

        XCTAssertEqual(second.map(\.itemId), ["d", "b"])
    }

    func testTheCountIsTheNumberOfRowsWhateverThePage() async throws {
        let searches: [RssStore.ItemSearch] = [
            .init(text: "ferry"), .init(text: "ferry", unread: true), .init(flag: .any),
            .init(text: "harbour", since: day(2)), .init(text: "nothing-matches-this"),
        ]
        for search in searches {
            let rows = try await store.search(search, limit: 100)
            let count = try await store.searchCount(search)
            XCTAssertEqual(count, rows.count, "\(search)")
        }
        let ferry = try await store.searchCount(.init(text: "ferry"))
        let firstPage = try await store.search(.init(text: "ferry"), limit: 2)
        XCTAssertEqual(ferry, 5)
        XCTAssertEqual(firstPage.count, 2, "the count is the whole search's, not the page's")
    }
}
