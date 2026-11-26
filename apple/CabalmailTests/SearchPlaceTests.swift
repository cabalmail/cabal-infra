import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window's search across both media (`SearchPlace`): what a submit
/// runs under each scope, what a pick of the control runs, what the
/// filters do to the feed half, and what clearing the search clears.
@MainActor
final class SearchPlaceTests: XCTestCase {
    private var fixture: SearchFixture!

    override func setUp() async throws {
        fixture = try await SearchFixture()
        try await fixture.addArticle("old", day: 2, title: "Ferry timetable")
        try await fixture.addArticle("new", day: 9, title: "Ferry strike", feed: "f2")
        try await fixture.addArticle("other", day: 5, title: "Harbour dredging")
        await fixture.imap.scriptSearch(SearchFixture.mailResult([4, 3], total: 2))
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var place: SearchPlace { fixture.place }
    private var model: MessageListViewModel { fixture.model }

    // MARK: A submit

    func testUnderAllASubmitSearchesBothMedia() async throws {
        await fixture.submit("ferry")

        XCTAssertEqual(place.scope, .all)
        XCTAssertEqual(place.submitted, "ferry")
        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, ["ferry"])
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3])
        XCTAssertEqual(fixture.articleKeys, ["new", "old"], "newest first, across both feeds")
        XCTAssertEqual(place.feeds.total, 2)
        XCTAssertEqual(place.feeds.feedName(for: place.feeds.rows[0]), "Tide Tables")
    }

    func testUnderFeedsASubmitSendsNothingToTheServer() async throws {
        place.noteFront(.feeds)

        await fixture.submit("ferry")

        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, [], "the mail search is not run")
        XCTAssertFalse(model.isSearchActive)
        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
        XCTAssertTrue(place.searchInProgress)
    }

    func testUnderMailASubmitDoesNotReadTheFeedStore() async throws {
        place.noteFront(.mail)

        await fixture.submit("ferry")

        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, ["ferry"])
        XCTAssertEqual(fixture.articleKeys, [])
        XCTAssertNil(place.feeds.search)
    }

    func testTheTermIsTrimmedForBothHalves() async throws {
        await fixture.submit("  ferry ")

        XCTAssertEqual(place.submitted, "ferry")
        XCTAssertEqual(place.feeds.search?.text, "ferry")
    }

    func testASubmitWithNothingToMatchOnEndsTheSearch() async throws {
        await fixture.submit("ferry")
        await place.pick(.feeds)

        await fixture.submit("   ")

        XCTAssertNil(place.submitted)
        XCTAssertEqual(fixture.articleKeys, [])
        XCTAssertFalse(model.isSearchActive)
        XCTAssertFalse(place.searchInProgress)
        XCTAssertEqual(place.scope, .all, "the pick went with the search")
    }

    // MARK: A pick of the control

    func testAPickBeforeAnythingIsSubmittedRunsNothing() async throws {
        model.searchQuery = "ferry"

        await place.pick(.feeds)

        XCTAssertEqual(place.scope, .feeds)
        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, [])
        XCTAssertEqual(fixture.articleKeys, [], "a typed term is not a search until it is submitted")
    }

    func testPickingFeedsAfterAMailSearchRunsTheFeedHalfForTheSameTerm() async throws {
        place.noteFront(.mail)
        await fixture.submit("ferry")

        await place.pick(.feeds)

        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, ["ferry"], "the mail half is not asked again")
    }

    func testPickingAllAfterAFeedSearchRunsTheMailHalfForTheSameTerm() async throws {
        place.noteFront(.feeds)
        await fixture.submit("ferry")

        await place.pick(.all)

        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, ["ferry"])
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3])
        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
    }

    func testAPickOfAScopeBothHalvesAlreadyHoldAsksForNothing() async throws {
        await fixture.submit("ferry")
        await place.pick(.mail)
        await place.pick(.feeds)

        await place.pick(.all)

        let terms = await fixture.mailTerms()
        XCTAssertEqual(terms, ["ferry"], "one request for the whole visit")
        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
    }

    // MARK: Filters

    func testASharedFilterNarrowsTheFeedHalf() async throws {
        try await fixture.addArticle("flagged", day: 7, title: "Ferry fares", favorite: true)
        model.search.filters.flagged = true

        await fixture.submit("ferry")

        XCTAssertEqual(fixture.articleKeys, ["flagged"])
        let flagged = await fixture.imap.searchCalls.map(\.flagged)
        XCTAssertEqual(flagged, [true], "and the mail half, as it always has")
    }

    func testAMailOnlyFilterStopsTheFeedHalfAndSaysWhich() async throws {
        await fixture.submit("ferry")
        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
        model.search.filters.from = "port@example.com"

        await place.submit()

        XCTAssertEqual(place.feedPlan, .blocked([.from]))
        XCTAssertEqual(fixture.articleKeys, [], "the unfiltered search's articles do not stand in")
        XCTAssertEqual(fixture.sections().feeds, .blocked([.from]))
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3], "mail is searched with the filter")
    }

    func testClearingTheMailOnlyFiltersSearchesFeedsAgain() async throws {
        model.search.filters.from = "port@example.com"
        model.search.filters.unread = true
        await fixture.submit("ferry")
        XCTAssertEqual(fixture.sections().feeds, .blocked([.from]))

        model.search.filters = FeedSearchPlan.clearingMailOnly(model.search.filters)
        await place.submit()

        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
        XCTAssertEqual(place.feeds.search?.unread, true, "the shared filter stayed")
    }

    func testAFilterChangedUnderMailReachesTheFeedHalfAtTheNextPick() async throws {
        try await fixture.addArticle("flagged", day: 7, title: "Ferry fares", favorite: true)
        await fixture.submit("ferry")
        await place.pick(.mail)
        // The mail list's own filter sheet: it re-runs mail and nothing else.
        model.search.filters.flagged = true
        await model.runSearch(resetFilterTab: false)

        await place.pick(.all)

        XCTAssertEqual(fixture.articleKeys, ["flagged"])
    }

    // MARK: Sections

    func testEachSectionReportsItsOwnHalf() async throws {
        await fixture.submit("ferry")

        let sections = fixture.sections()
        XCTAssertEqual(sections.mail, .rows(total: 2, truncated: false, stale: false))
        XCTAssertEqual(sections.feeds, .rows(total: 2))
        XCTAssertEqual(sections.mailCount, "2")
        XCTAssertEqual(sections.feedCount, "2")
        XCTAssertFalse(sections.nothingMatched)
    }

    func testAllListsTheFirstFiveMessages() async throws {
        await fixture.imap.scriptSearch(SearchFixture.mailResult([9, 8, 7, 6, 5, 4, 3], total: 40))

        await fixture.submit("ferry")

        XCTAssertEqual(SearchSections.mailHits(in: model).map(\.envelope.uid), [9, 8, 7, 6, 5])
        XCTAssertEqual(SearchSections.mailHits(in: model).first?.id,
                       .mail(MessageRef(folder: "INBOX", uid: 9)), "a row is its message in its own folder")
        XCTAssertEqual(fixture.sections().mail, .rows(total: 40, truncated: false, stale: false))
    }

    func testAFailedMailSearchLeavesTheFeedResultsUp() async throws {
        let stranded = try await SearchFixture()
        defer { stranded.tearDown() }
        try await stranded.addArticle("a", day: 3, title: "Ferry timetable")

        // Nothing is scripted for this fixture's mail client, so its search throws.
        await stranded.submit("ferry")

        XCTAssertEqual(stranded.sections().mail, .failed(offline: false))
        XCTAssertEqual(stranded.sections(isOffline: true).mail, .failed(offline: true))
        XCTAssertEqual(stranded.sections().feeds, .rows(total: 1))
        XCTAssertFalse(stranded.sections().nothingMatched, "a failure is not an answer of nothing")
    }

    func testRetryAsksTheServerAgainForTheSubmittedTerm() async throws {
        let stranded = try await SearchFixture()
        defer { stranded.tearDown() }
        await stranded.submit("ferry")
        XCTAssertEqual(stranded.sections().mail, .failed(offline: false))
        // The connection is back; the field has been typed in since.
        await stranded.imap.scriptSearch(SearchFixture.mailResult([4]))
        stranded.model.searchQuery = "ferry timetable"

        await stranded.place.retryMail()

        let terms = await stranded.mailTerms()
        XCTAssertEqual(terms, ["ferry", "ferry"], "the search that failed, not the text typed since")
        XCTAssertEqual(stranded.sections().mail, .rows(total: 1, truncated: false, stale: false))
    }

    func testNothingMatchedNeedsEverySectionInScopeToAnswerEmpty() async throws {
        await fixture.imap.scriptSearch(SearchFixture.mailResult([]))

        await fixture.submit("ferry")
        XCTAssertFalse(fixture.sections().nothingMatched, "the feeds matched")

        await fixture.submit("zeppelin")
        XCTAssertEqual(fixture.sections().mail, .empty)
        XCTAssertEqual(fixture.sections().feeds, .empty)
        XCTAssertTrue(fixture.sections().nothingMatched)
    }

    // MARK: Ending

    func testEndingTheSearchClearsThePickTheTermTheArticlesAndTheOpenArticle() async throws {
        place.noteFront(.mail)
        await fixture.submit("ferry")
        await place.pick(.all)
        place.openArticle = place.feeds.rows.first

        place.searchEnded()

        XCTAssertEqual(place.scope, .mail, "back to the medium in front")
        XCTAssertNil(place.submitted)
        XCTAssertNil(place.openArticle)
        XCTAssertEqual(fixture.articleKeys, [])
        XCTAssertNil(place.feedPlan)
    }

    func testATypedTermIsASearchInProgress() {
        XCTAssertFalse(place.searchInProgress)

        model.searchQuery = "fer"

        XCTAssertTrue(place.searchInProgress)
        place.noteFront(.feeds)
        XCTAssertEqual(place.scope, .all, "what comes in front does not move a search already begun")
    }

    func testLeavingALayoutHandsTheOpenArticleOnOnce() async throws {
        await fixture.submit("ferry")
        let article = try XCTUnwrap(place.feeds.rows.first)
        place.openArticle = article

        XCTAssertEqual(place.leaveLayout(), article)
        XCTAssertNil(place.openArticle, "the layout it was open in is gone")
        XCTAssertNil(place.leaveLayout())
        XCTAssertEqual(place.scope, .all, "the search and its scope carry")
        XCTAssertEqual(fixture.articleKeys, ["new", "old"])
    }
}
