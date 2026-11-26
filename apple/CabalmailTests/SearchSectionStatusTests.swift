import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What each section of a search's results shows while its half is
/// loading, failed, empty or answered, and the words it uses.
final class SearchSectionStatusTests: XCTestCase {

    private func mail(
        active: Bool = false, loading: Bool = false, error: Bool = false, offline: Bool = false, rows: Int = 0,
        total: Int = 0, truncated: Bool = false
    ) -> MailSectionStatus {
        MailSectionStatus(
            isActive: active, isLoading: loading, hasError: error, isOffline: offline, rowCount: rows,
            total: total, truncated: truncated
        )
    }

    // MARK: Mail

    func testMailBeforeAnythingIsSent() {
        XCTAssertEqual(mail(), .idle)
    }

    func testMailWhileItsFirstRequestIsOut() {
        XCTAssertEqual(mail(loading: true), .searching)
    }

    func testMailThatFailedWithNothingToShow() {
        XCTAssertEqual(mail(error: true), .failed(offline: false))
        XCTAssertEqual(mail(error: true, offline: true), .failed(offline: true))
        XCTAssertEqual(mail(loading: true, error: true), .searching, "a retry is out: the old error is not news")
    }

    func testMailThatAnsweredWithNothing() {
        XCTAssertEqual(mail(active: true), .empty)
        XCTAssertTrue(mail(active: true).isEmpty)
        XCTAssertFalse(mail().isEmpty, "not searched is not searched and found empty")
    }

    func testMailWithRows() {
        XCTAssertEqual(mail(active: true, rows: 5, total: 37), .rows(total: 37, truncated: false, stale: false))
        XCTAssertEqual(mail(active: true, rows: 5, total: 5000, truncated: true),
                       .rows(total: 5000, truncated: true, stale: false))
        XCTAssertEqual(mail(active: true, rows: 3, total: 1), .rows(total: 3, truncated: false, stale: false),
                       "never fewer than the rows on screen")
    }

    func testMailRowsStayUnderAFailedRefresh() {
        XCTAssertEqual(mail(active: true, error: true, rows: 5, total: 9),
                       .rows(total: 9, truncated: false, stale: true))
        XCTAssertEqual(mail(active: true, loading: true, rows: 5, total: 9),
                       .rows(total: 9, truncated: false, stale: false), "rows stay while a refresh is out")
    }

    // MARK: Feeds

    private let search = FeedSearchPlan.search(RssStore.ItemSearch(text: "ferry"))

    func testFeedsBeforeAnythingIsAsked() {
        XCTAssertEqual(FeedSectionStatus(plan: nil, loaded: false, failed: false, rowCount: 0, total: 0), .idle)
        XCTAssertEqual(FeedSectionStatus(plan: .nothing, loaded: true, failed: false, rowCount: 0, total: 0), .idle)
        XCTAssertEqual(FeedSectionStatus(plan: search, loaded: false, failed: false, rowCount: 0, total: 0), .idle,
                       "asked and not yet read is not empty")
    }

    func testFeedsUnderAMailOnlyFilterAreNotSearched() {
        let status = FeedSectionStatus(
            plan: .blocked([.from, .subject]), loaded: true, failed: false, rowCount: 4, total: 4
        )

        XCTAssertEqual(status, .blocked([.from, .subject]), "whatever rows an earlier search left")
        XCTAssertFalse(status.isEmpty)
    }

    func testFeedsThatAnswered() {
        XCTAssertEqual(FeedSectionStatus(plan: search, loaded: true, failed: false, rowCount: 0, total: 0), .empty)
        XCTAssertEqual(FeedSectionStatus(plan: search, loaded: true, failed: false, rowCount: 5, total: 12),
                       .rows(total: 12))
        XCTAssertEqual(FeedSectionStatus(plan: search, loaded: true, failed: true, rowCount: 5, total: 12),
                       .unreadable)
    }

    // MARK: Words

    func testASectionOffersTheRestOnlyWhenThereIsARest() {
        XCTAssertNil(SearchSectionWords.showAllMail(total: 5, truncated: false))
        XCTAssertEqual(SearchSectionWords.showAllMail(total: 6, truncated: false), "Show all 6 messages")
        XCTAssertEqual(SearchSectionWords.showAllMail(total: 5000, truncated: true), "Show all messages",
                       "the server's cap is not passed off as the total")
        XCTAssertNil(SearchSectionWords.showAllFeeds(total: 5))
        XCTAssertEqual(SearchSectionWords.showAllFeeds(total: 12), "Show all 12 articles")
        XCTAssertEqual(SearchSectionWords.digestLimit, 5)
    }

    func testTheCountSaysWhenTheServerStoppedCounting() {
        XCTAssertEqual(SearchSectionWords.count(37), "37")
        XCTAssertEqual(SearchSectionWords.count(37, truncated: true), "37+")
    }

    func testTheBlockedLineNamesTheFilters() {
        XCTAssertEqual(SearchSectionWords.feedsBlocked(by: [.from]), "Feeds are not searched while From is set.")
        XCTAssertEqual(SearchSectionWords.feedsBlocked(by: [.from, .hasAttachment]),
                       "Feeds are not searched while From and Has attachment are set.")
    }

    func testTheFailureSaysWhenItIsTheConnection() {
        XCTAssertEqual(SearchSectionWords.mailFailed(offline: true), "Searching mail needs a connection.")
        XCTAssertEqual(SearchSectionWords.mailFailed(offline: false), "Mail could not be searched.")
    }

    func testNothingMatchedNamesTheMediaThatWereAsked() {
        XCTAssertEqual(SearchSectionWords.nothingMatched("ferry", scope: .all),
                       "No messages or downloaded articles matched \u{201C}ferry\u{201D}.")
        XCTAssertEqual(SearchSectionWords.nothingMatched("ferry", scope: .feeds),
                       "No downloaded articles matched \u{201C}ferry\u{201D}.")
        XCTAssertEqual(SearchSectionWords.nothingMatched("", scope: .mail), "No messages matched your search.")
    }
}
