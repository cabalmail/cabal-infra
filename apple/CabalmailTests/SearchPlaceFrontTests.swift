import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a window's search opens on when the window says what is in front
/// at other moments than the search's own (`SearchPlace.noteFront`): the
/// Mac's list column says it while nothing is searched, since its results
/// are not up until a term is typed, and a pick in the sidebar ends a
/// search and moves what is in front in one turn.
@MainActor
final class SearchPlaceFrontTests: XCTestCase {
    private var fixture: SearchFixture!

    override func setUp() async throws {
        fixture = try await SearchFixture()
        try await fixture.addArticle("old", day: 2, title: "Ferry timetable")
        try await fixture.addArticle("new", day: 9, title: "Ferry strike", feed: "f2")
        await fixture.imap.scriptSearch(SearchFixture.mailResult([4, 3], total: 2))
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var place: SearchPlace { fixture.place }
    private var model: MessageListViewModel { fixture.model }

    func testWhatCameInFrontBetweenSearchesIsWhatTheNextOpensOn() async throws {
        place.noteFront(.mail)
        await fixture.submit("ferry")
        model.searchQuery = ""
        place.searchEnded()
        await model.clearSearch()

        // A feed list is picked, with no search: the column says so.
        place.noteFront(.feeds)
        // The first key of the next search is the first the results see.
        model.searchQuery = "f"

        XCTAssertEqual(place.scope, .feeds)
        place.noteFront(.mail)
        XCTAssertEqual(place.scope, .feeds, "and that search now holds it")
    }

    func testAPickThatEndsASearchMovesTheScopeWhileTheMailRowsAreStillUp() async throws {
        place.noteFront(.mail)
        await fixture.submit("ferry")
        XCTAssertTrue(model.isSearchActive)

        // The sidebar's pick of a feed: the field is emptied and the search
        // ended at once, and the mail list clears its rows a turn later.
        model.searchQuery = ""
        place.searchEnded()
        place.noteFront(.feeds)

        XCTAssertTrue(model.isSearchActive, "the rows of the ended search are still there")
        XCTAssertEqual(place.scope, .feeds, "and are not a search that holds its scope")
        await model.clearSearch()
        XCTAssertEqual(place.scope, .feeds)
    }

    func testASearchTheMailListBeganItselfHoldsItsScopeAndAnswersAPick() async throws {
        try await fixture.store.setRead(feedId: "f1", sortKey: "2026-03-02T12:00:00Z#old", true)
        place.noteFront(.mail)
        // The mail list's own filter sheet, applied with nothing typed.
        model.search.filters.unread = true
        await model.runSearch(resetFilterTab: false)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertNil(place.submitted, "the place did not submit it")

        place.mailSearchBegan()

        XCTAssertEqual(place.submitted, "")
        place.noteFront(.feeds)
        XCTAssertEqual(place.scope, .mail, "the Search tab was left and opened again from Feeds")
        await place.pick(.all)
        XCTAssertEqual(fixture.articleKeys, ["new"], "the feed half answers the same filter")
        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms.count, 1, "and the mail half is not run a second time")
    }

    func testASearchThePlaceSubmittedIsNotAdoptedOver() async throws {
        // Submitted under Feeds, so the mail half has run no term at all.
        place.noteFront(.feeds)
        await fixture.submit("ferry")
        XCTAssertEqual(model.search.submittedQuery, "")

        place.mailSearchBegan()

        XCTAssertEqual(place.submitted, "ferry", "the term both halves answer to is the place's")
    }

    func testATypedTermCarriesItsScopeAcrossAChangeOfLayout() {
        place.noteFront(.feeds)
        model.searchQuery = "fer"

        _ = place.leaveLayout()
        XCTAssertEqual(place.scope, .feeds)
        // The new layout's column says what is in front of it.
        place.noteFront(.mail)
        XCTAssertEqual(place.scope, .feeds)

        model.searchQuery = ""
        place.searchEnded()
        XCTAssertEqual(place.scope, .mail)
    }

    func testAChangeOfLayoutWithNoSearchForgetsWhatWasInFront() {
        place.noteFront(.feeds)

        _ = place.leaveLayout()

        XCTAssertEqual(place.scope, .all)
    }
}
