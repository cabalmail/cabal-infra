import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the two sections of a search's results show (`SearchSections`),
/// read from the window's search model and its search place: each half's
/// own state, the rows All lists, and when the screen says nothing matched.
@MainActor
final class SearchSectionsTests: XCTestCase {
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

    // MARK: What the sections list

    func testAllListsTheFirstFiveArticlesAndFeedsListsThemAll() async throws {
        try await fixture.addFerryArticles(7)

        await fixture.submit("ferry")
        XCTAssertEqual(SearchFeedSectionRows.rows(of: place).count, 5)
        XCTAssertEqual(SearchFeedSectionRows.rows(of: place).first?.itemId, "new", "the newest five")

        await place.pick(.feeds)
        XCTAssertEqual(SearchFeedSectionRows.rows(of: place).count, 9)
    }

    func testTheFiltersBadgeCountsOnlyWhatTheScopeOffers() {
        var filters = MessageSearchFilters()
        filters.from = "port@example.com"
        filters.hasAttachment = true
        filters.unread = true

        XCTAssertEqual(SearchResultsControls.activeFilters(filters, scope: .all), 3)
        XCTAssertEqual(SearchResultsControls.activeFilters(filters, scope: .feeds), 1,
                       "under Feeds the sheet offers Unread, not From or Has attachment")
    }

    func testUnderFeedsNothingMatchedIsTheFeedHalfsAnswerAlone() async throws {
        place.noteFront(.feeds)

        await fixture.submit("zeppelin")

        XCTAssertEqual(fixture.sections().mail, .idle, "mail was never asked")
        XCTAssertEqual(fixture.sections().feeds, .empty)
        XCTAssertTrue(fixture.sections().nothingMatched)
    }
}
