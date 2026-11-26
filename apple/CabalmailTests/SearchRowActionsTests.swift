import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a swipe or a menu item on a search result does
/// (`SearchRowActions`): a message's through the window's search model,
/// an article's through the feed half.
@MainActor
final class SearchRowActionsTests: XCTestCase {
    private var fixture: SearchFixture!

    override func setUp() async throws {
        fixture = try await SearchFixture()
        try await fixture.addArticle("a", day: 3, title: "Ferry timetable")
        await fixture.imap.scriptSearch(SearchFixture.mailResult([4, 3]))
        await fixture.submit("ferry")
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var actions: SearchRowActions {
        SearchRowActions(model: fixture.model, place: fixture.place, preferences: fixture.preferences)
    }

    func testAMessagesReadSwipeWritesInTheMessagesOwnFolder() async throws {
        let envelope = try XCTUnwrap(fixture.model.envelopes.first)
        let spec = try XCTUnwrap(actions.mailSwipe(.toggleRead, envelope: envelope))
        XCTAssertEqual(spec.title, "Read")

        spec.perform()

        try await waitUntilOnMainActor { await !self.fixture.imap.flagCalls.isEmpty }
        let calls = await fixture.imap.flagCalls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.folder, "INBOX")
        XCTAssertEqual(call.uids, [4])
        XCTAssertEqual(call.flags, [.seen])
    }

    func testAMessagesDisposeIsThePlainMoveThePreferenceNames() async throws {
        let envelope = try XCTUnwrap(fixture.model.envelopes.first)
        fixture.preferences.disposeAction = .trash

        let spec = try XCTUnwrap(actions.mailSwipe(.dispose, envelope: envelope))

        XCTAssertEqual(spec.title, "Trash")
        fixture.preferences.disposeAction = .archive
        XCTAssertEqual(actions.mailSwipe(.dispose, envelope: envelope)?.title, "Archive")
    }

    func testADisabledEdgeHasNoSwipe() throws {
        let envelope = try XCTUnwrap(fixture.model.envelopes.first)
        let item = try XCTUnwrap(fixture.place.feeds.rows.first)

        XCTAssertNil(actions.mailSwipe(.disabled, envelope: envelope))
        XCTAssertNil(actions.feedSwipe(.disabled, item: item))
    }

    func testAnArticlesFlagSwipeSetsTheDefaultFlagInTheStore() async throws {
        let item = try XCTUnwrap(fixture.place.feeds.rows.first)
        let spec = try XCTUnwrap(actions.feedSwipe(.toggleFavorite, item: item))

        spec.perform()

        try await waitUntilOnMainActor { self.fixture.place.feeds.rows.first?.isFavorite == true }
        let stored = try await fixture.store.item(feedId: item.feedId, sortKey: item.sortKey)
        XCTAssertEqual(stored?.isFavorite, true)
    }

    func testOpeningAnArticleMarksItReadOnlyWhenTheFeedReadersPreferenceSaysSo() async throws {
        let item = try XCTUnwrap(fixture.place.feeds.rows.first)
        fixture.preferences.rssMarkAsRead = .manual

        await actions.didOpen(item)
        let untouched = try await fixture.store.item(feedId: item.feedId, sortKey: item.sortKey)
        XCTAssertEqual(untouched?.isRead, false)

        fixture.preferences.rssMarkAsRead = .onOpen
        await actions.didOpen(item)
        let read = try await fixture.store.item(feedId: item.feedId, sortKey: item.sortKey)
        XCTAssertEqual(read?.isRead, true)
    }
}
