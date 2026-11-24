import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a feed item's row in the Flagged view writes, and what a write
/// does to the list: a cleared flag takes its row out at once, ahead of
/// the server, and the list follows what the feed reader wrote.
@MainActor
final class FlaggedFeedRowWritesTests: XCTestCase {
    private typealias Fixture = FlaggedFixture
    private var fixture: FlaggedFixture!

    override func setUp() async throws {
        fixture = try await FlaggedFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    /// A row a test asked for is not in the list: a failure, never a skip.
    private struct NotLoaded: Error {
        let what: String
    }

    private func feedRow(_ key: String, in model: FlaggedListViewModel) throws -> RssItem {
        guard case .feed(let item)? = model.row(for: .feed(feedID: "f", sortKey: key)) else {
            throw NotLoaded(what: key)
        }
        return item
    }

    func testAFeedItemWhoseFlagIsClearedLeavesAtOnce() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("b", "2026-03-04T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a", "b"])
        let actions = FlaggedRowActions(model: model)
        let spec = try XCTUnwrap(actions.feedSwipe(.toggleFavorite, item: try feedRow("a", in: model)))
        XCTAssertEqual(spec.title, "Unflag")

        spec.perform()

        await fixture.expect(model, shows: ["b"])
        let stored = try await fixture.store.item(feedId: "f", sortKey: "a")
        XCTAssertEqual(stored?.isFavorite, false)
    }

    /// "At once" is ahead of the server, which the write waits on: the row
    /// is gone while the push is still out.
    func testAClearedFeedFlagTakesItsRowBeforeTheServerAnswers() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("b", "2026-03-04T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a", "b"])
        let item = try feedRow("a", in: model)
        await fixture.rss.holdNext(.push)

        let write = Task { await model.toggleDefaultFlag(on: item) }
        try await waitUntilOnMainActor { await self.fixture.rss.isHolding(.push) }

        XCTAssertEqual(Fixture.names(model), ["b"])
        await fixture.rss.releaseHeld(.push)
        await write.value
        XCTAssertEqual(Fixture.names(model), ["b"])
    }

    func testOpeningAnItemMarksItReadOnlyWhenTheFeedReadersPreferenceSaysSo() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a"])

        fixture.preferences.rssMarkAsRead = .manual
        await model.didOpen(try feedRow("a", in: model))
        XCTAssertFalse(try feedRow("a", in: model).isRead)

        fixture.preferences.rssMarkAsRead = .onOpen
        await model.didOpen(try feedRow("a", in: model))
        XCTAssertTrue(try feedRow("a", in: model).isRead)
    }

    /// The feed reader writes through the engine, and the list follows the
    /// store: a flag cleared there takes the row, and set again brings it back.
    func testTheListFollowsAFlagChangedInTheFeedReader() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a"])
        let following = Task { await model.observe() }
        defer { following.cancel() }
        let item = try feedRow("a", in: model)
        let engine = RssSyncEngine(client: fixture.rss, store: fixture.store)

        try await engine.setFavorite(item, false)
        await fixture.expect(model, shows: [])

        try await engine.setFavorite(item, true)
        await fixture.expect(model, shows: ["a"])
    }

    func testAFeedItemsReadMarkIsWrittenAndItsRowStays() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a"])
        let actions = FlaggedRowActions(model: model)
        let spec = try XCTUnwrap(actions.feedSwipe(.toggleRead, item: try feedRow("a", in: model)))
        XCTAssertEqual(spec.title, "Mark read")

        spec.perform()

        try await waitUntilOnMainActor { (try? self.feedRow("a", in: model).isRead) == true }
        XCTAssertEqual(Fixture.names(model), ["a"])
    }
}
