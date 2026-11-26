import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed half of a search (`FeedSearchSession`): its pages, what a mark
/// on a row does to it, and how it follows the store.
@MainActor
final class FeedSearchSessionTests: XCTestCase {
    private var fixture: SearchFixture!

    override func setUp() async throws {
        fixture = try await SearchFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var session: FeedSearchSession { fixture.place.feeds }
    private let ferry = RssStore.ItemSearch(text: "ferry")

    func testTheFirstPageIsFiftyAndTheCountIsTheWholeSearch() async throws {
        try await fixture.addFerryArticles(60)

        await session.run(ferry, in: fixture.feeds)

        XCTAssertEqual(session.rows.count, FeedSearchSession.pageSize)
        XCTAssertEqual(session.total, 60)
        XCTAssertTrue(session.hasMore)
        XCTAssertTrue(session.loaded)
        XCTAssertEqual(session.rows.first?.itemId, "a60", "newest first")
    }

    func testTheNextPageAppendsWithoutRepeatingARow() async throws {
        try await fixture.addFerryArticles(60)
        await session.run(ferry, in: fixture.feeds)

        await session.loadMore(in: fixture.feeds)

        XCTAssertEqual(session.rows.count, 60)
        XCTAssertEqual(Set(session.rows.map(\.id)).count, 60)
        XCTAssertFalse(session.hasMore)
        XCTAssertEqual(session.rows.last?.itemId, "a01")

        await session.loadMore(in: fixture.feeds)
        XCTAssertEqual(session.rows.count, 60, "nothing more to ask for")
    }

    func testADifferentSearchStartsFromNothing() async throws {
        try await fixture.addFerryArticles(3)
        try await fixture.addArticle("h", day: 4, title: "Harbour dredging")
        await session.run(ferry, in: fixture.feeds)
        XCTAssertEqual(session.rows.count, 3)

        await session.run(RssStore.ItemSearch(text: "harbour"), in: fixture.feeds)

        XCTAssertEqual(fixture.articleKeys, ["h"])
        XCTAssertEqual(session.total, 1)
    }

    func testClearingForgetsTheSearch() async throws {
        try await fixture.addFerryArticles(3)
        await session.run(ferry, in: fixture.feeds)

        session.clear()

        XCTAssertNil(session.search)
        XCTAssertEqual(session.rows, [])
        XCTAssertEqual(session.total, 0)
        XCTAssertFalse(session.loaded)
        // A reload after the clear brings nothing back.
        await session.reload(in: fixture.feeds)
        XCTAssertEqual(session.rows, [])
    }

    func testABareClientAnswersWithNothing() async throws {
        await session.run(ferry, in: FlaggedFeedStore(store: nil, engine: nil))

        XCTAssertEqual(session.rows, [])
        XCTAssertTrue(session.loaded, "no feed store is an answer of nothing, not a wait")
        XCTAssertFalse(session.failed)
    }

    // MARK: Marks

    func testMarkingARowReadWritesTheStoreAndKeepsTheRow() async throws {
        try await fixture.addFerryArticles(2)
        await session.run(ferry, in: fixture.feeds)
        let row = try XCTUnwrap(session.rows.first)
        XCTAssertFalse(row.isRead)

        await session.setRead(row, true, in: fixture.feeds)

        XCTAssertEqual(session.rows.first?.isRead, true)
        let stored = try await fixture.store.item(feedId: row.feedId, sortKey: row.sortKey)
        XCTAssertEqual(stored?.isRead, true)
        XCTAssertEqual(session.rows.count, 2)
    }

    func testARowTheMarkTakesOutOfTheSearchLeaves() async throws {
        try await fixture.addFerryArticles(2)
        await session.run(RssStore.ItemSearch(text: "ferry", unread: true), in: fixture.feeds)
        let row = try XCTUnwrap(session.rows.first)

        await session.setRead(row, true, in: fixture.feeds)

        XCTAssertEqual(fixture.articleKeys, ["a01"], "an unread search no longer finds a read article")
        XCTAssertEqual(session.total, 1)
    }

    func testTheReadToggleGoesByTheStoresCopy() async throws {
        try await fixture.addFerryArticles(1)
        await session.run(ferry, in: fixture.feeds)
        let stale = try XCTUnwrap(session.rows.first)
        // Read elsewhere since this copy was made: a reader, another window.
        try await fixture.store.setRead(feedId: stale.feedId, sortKey: stale.sortKey, true)

        await session.toggleRead(stale, in: fixture.feeds)

        let stored = try await fixture.store.item(feedId: stale.feedId, sortKey: stale.sortKey)
        XCTAssertEqual(stored?.isRead, false, "read in the store, so the toggle marks it unread")
    }

    func testTheFlagToggleSetsAndClears() async throws {
        try await fixture.addFerryArticles(1)
        await session.run(ferry, in: fixture.feeds)
        let row = try XCTUnwrap(session.rows.first)

        await session.toggleFlag(slot: FlagPalette.systemSlot, on: row, in: fixture.feeds)
        XCTAssertEqual(session.rows.first?.isFavorite, true)

        await session.toggleFlag(slot: FlagPalette.systemSlot, on: row, in: fixture.feeds)
        XCTAssertEqual(session.rows.first?.isFavorite, false, "by the store's copy, not the caller's older one")
    }

    func testARowsMarkShowsBeforeTheServerAnswers() async throws {
        try await fixture.addFerryArticles(1)
        await session.run(ferry, in: fixture.feeds)
        let row = try XCTUnwrap(session.rows.first)
        await fixture.rss.holdNext(.push)

        let write = Task { await self.session.setRead(row, true, in: self.fixture.feeds) }
        try await waitUntilOnMainActor { await self.fixture.rss.isHolding(.push) }

        XCTAssertEqual(session.rows.first?.isRead, true)
        await fixture.rss.releaseHeld(.push)
        await write.value
    }

    // MARK: Following the store

    func testAChangeInTheStoreReachesTheRows() async throws {
        try await fixture.addFerryArticles(2)
        await session.run(ferry, in: fixture.feeds)
        let observing = Task { await self.session.observe(in: self.fixture.feeds) }
        defer { observing.cancel() }

        // Written until the rows show it: the observer hears only writes
        // made after it has subscribed, and a write of the same article
        // twice is one article.
        try await waitUntilOnMainActor {
            try? await self.fixture.addArticle("late", day: 20, title: "Ferry late news")
            return self.fixture.articleKeys.first == "late"
        }
        XCTAssertEqual(session.total, 3)
    }

    func testAMarkAfterTwoPagesKeepsBothPages() async throws {
        try await fixture.addFerryArticles(60)
        await session.run(ferry, in: fixture.feeds)
        await session.loadMore(in: fixture.feeds)
        let row = try XCTUnwrap(session.rows.first)

        await session.setRead(row, true, in: fixture.feeds)

        XCTAssertEqual(session.rows.count, 60, "the rows the user has paged in are still there")
        XCTAssertEqual(session.rows.first?.isRead, true)
    }

    func testAPageIsFifty() {
        XCTAssertEqual(FeedSearchSession.pageSize, 50, "the mail search's page, so the two sections fill alike")
    }
}
