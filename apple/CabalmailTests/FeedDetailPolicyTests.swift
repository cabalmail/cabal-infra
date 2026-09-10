import XCTest
import CabalmailKit
@testable import Cabalmail

/// What the feed reader opens first, from the subscription's stored
/// preferences (D6 clarification: "show article" opens the publisher's page).
@MainActor
final class FeedDetailPolicyTests: XCTestCase {
    func testDefaultsAreSummaryInReaderStyling() {
        let initial = FeedDetailPolicy.initial(for: nil, hasArticleURL: true)
        XCTAssertEqual(initial, .init(showsArticle: false, readerMode: true))
    }

    func testArticleModeNeedsALink() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: .article, defaultStyling: .native)
        XCTAssertEqual(FeedDetailPolicy.initial(for: sub, hasArticleURL: true),
                       .init(showsArticle: true, readerMode: false))
        XCTAssertEqual(FeedDetailPolicy.initial(for: sub, hasArticleURL: false),
                       .init(showsArticle: false, readerMode: false))
    }

    func testReaderDocumentEscapesTitleAndKeepsContent() {
        let article = ExtractedArticle(title: "A <b> & B", byline: "By Ann", content: "<p>Body</p>")
        let html = ArticleReaderDocument.html(for: article, sourceHost: "example.com")
        XCTAssertTrue(html.contains("<h1>A &lt;b&gt; &amp; B</h1>"))
        XCTAssertTrue(html.contains("By Ann · example.com"))
        XCTAssertTrue(html.contains("<p>Body</p>"))
        // Reader styling rides along, as it does for a reader-mode message.
        XCTAssertTrue(html.contains("!important"))
    }

    func testFeedItemDateHandlesServerTimestamps() {
        XCTAssertNotNil(FeedItemDate.date("2026-09-09T20:25:06+00:00"))
        XCTAssertNotNil(FeedItemDate.date("2026-09-09T20:25:06.634236+00:00"))
        XCTAssertEqual(FeedItemDate.relative("not a date"), "")
        XCTAssertEqual(FeedItemDate.feedLabel(for: RssItem(feedId: "f", itemId: "i", sortKey: "k",
                                                            url: "https://blog.rust-lang.org/x")),
                       "blog.rust-lang.org")
    }
}
