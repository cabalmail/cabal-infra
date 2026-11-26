import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a wide split's reader has open (`OpenReading`), which is what sends
/// the floating list away: an article opened from a search has to count,
/// or the list stays over the reader that has just filled.
final class OpenReadingTests: XCTestCase {
    private let article = RssItem(feedId: "f1", itemId: "a", sortKey: "k1", title: "Ferry strike")
    private let beneath = RssItem(feedId: "f2", itemId: "b", sortKey: "k2", title: "Tide tables")
    private let message = TestFixtures.makeEnvelope(uid: 9).inFolder("Archive")

    private func key(
        searchArticle: RssItem? = nil, flaggedShown: Bool = false, flaggedItem: FlaggedRow? = nil,
        readerShowsFeeds: Bool = false, feedItem: RssItem? = nil, envelope: Envelope? = nil
    ) -> String? {
        OpenReading(
            searchArticle: searchArticle, flaggedShown: flaggedShown, flaggedItem: flaggedItem,
            readerShowsFeeds: readerShowsFeeds, feedItem: feedItem, envelope: envelope
        ).key
    }

    func testNothingOpenIsNoKey() {
        XCTAssertNil(key())
        XCTAssertNil(key(readerShowsFeeds: true))
        XCTAssertNil(key(flaggedShown: true))
    }

    func testAnArticleOpenFromSearchIsAnOpenItem() {
        XCTAssertEqual(key(searchArticle: article, readerShowsFeeds: true), "article:\(article.id)")
    }

    func testTheSearchsArticleIsTheOneOpenNotTheFeedItemBeneath() {
        // The search was begun over a feed list with an item open in it.
        let over = key(searchArticle: article, readerShowsFeeds: true, feedItem: beneath)

        XCTAssertEqual(over, "article:\(article.id)")
        XCTAssertNotEqual(over, key(readerShowsFeeds: true, feedItem: beneath),
                          "opening the article is a new open, so the list goes away for it")
    }

    func testAnotherArticleIsANewOpen() {
        XCTAssertNotEqual(key(searchArticle: article), key(searchArticle: beneath))
    }

    func testAFeedItemCountsOnlyWhileTheReaderShowsFeeds() {
        XCTAssertEqual(key(readerShowsFeeds: true, feedItem: beneath), "item:\(beneath.id)")
        XCTAssertNil(key(readerShowsFeeds: false, feedItem: beneath))
    }

    func testAMessageIsKeyedByItsFolderToo() {
        XCTAssertEqual(key(envelope: message), "message:Archive#9")
        XCTAssertNotEqual(key(envelope: message), key(envelope: TestFixtures.makeEnvelope(uid: 9).inFolder("INBOX")))
    }

    func testTheFlaggedViewsRowIsTheOneOpenOverTheFolderBeneath() {
        let row = FlaggedRow.feed(article)

        XCTAssertEqual(key(flaggedShown: true, flaggedItem: row, envelope: message), "flagged:\(row.ref)")
        XCTAssertNil(key(flaggedShown: true, envelope: message), "the view with nothing open is nothing open")
    }
}
