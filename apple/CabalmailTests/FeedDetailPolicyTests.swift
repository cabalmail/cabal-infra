import XCTest
import CabalmailKit
@testable import Cabalmail

/// What the feed reader opens first, from the subscription's stored
/// preferences (D6 clarification: "show article" opens the publisher's page).
@MainActor
final class FeedDetailPolicyTests: XCTestCase {
    func testDefaultsAreSummaryInReaderStyling() {
        let initial = FeedDetailPolicy.initial(for: nil, hasArticleURL: true)
        XCTAssertEqual(initial, .init(showsArticle: false, readerMode: true, remoteContentAllowed: false))
    }

    func testRemoteContentInheritsTheGlobalPolicyUnlessTheFeedOverrides() {
        let inherit = RssSubscription(subscriptionId: "s", feedId: "f")
        XCTAssertFalse(FeedDetailPolicy.initial(for: inherit, hasArticleURL: true).remoteContentAllowed)
        XCTAssertFalse(FeedDetailPolicy.initial(for: inherit, hasArticleURL: true, globalRemoteContent: .ask)
            .remoteContentAllowed, "the feed reader has no per-item prompt, so Ask reads as off")
        XCTAssertTrue(FeedDetailPolicy.initial(for: inherit, hasArticleURL: true, globalRemoteContent: .always)
            .remoteContentAllowed)
        let show = RssSubscription(subscriptionId: "s", feedId: "f", defaultRemoteContent: .show)
        XCTAssertTrue(FeedDetailPolicy.initial(for: show, hasArticleURL: true).remoteContentAllowed)
        let hide = RssSubscription(subscriptionId: "s", feedId: "f", defaultRemoteContent: .hide)
        XCTAssertFalse(FeedDetailPolicy.initial(for: hide, hasArticleURL: true, globalRemoteContent: .always)
            .remoteContentAllowed)
    }

    func testStickyUpdateWritesOnlyTheToggledField() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f")
        let article = FeedDetailPolicy.stickyUpdate(for: sub, toggle: .article(showing: true), hasArticleURL: true)
        XCTAssertEqual(article?.defaultOpenMode, .article)
        XCTAssertNil(article?.defaultStyling)
        XCTAssertNil(article?.defaultRemoteContent, "flipping the article view must not pin remote content")
        let styling = FeedDetailPolicy.stickyUpdate(
            for: sub, toggle: .styling(readerMode: false), hasArticleURL: true
        )
        XCTAssertEqual(styling?.defaultStyling, .native)
        XCTAssertNil(styling?.defaultOpenMode)
        XCTAssertNil(styling?.customTitle)
    }

    func testStickyUpdateIsNilWhenTheStoredDefaultAlreadyMatches() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: .article,
                                  defaultStyling: .native, defaultRemoteContent: .show)
        XCTAssertNil(FeedDetailPolicy.stickyUpdate(for: sub, toggle: .article(showing: true), hasArticleURL: true))
        XCTAssertNil(FeedDetailPolicy.stickyUpdate(
            for: sub, toggle: .styling(readerMode: false), hasArticleURL: true
        ))
        XCTAssertNil(FeedDetailPolicy.stickyUpdate(
            for: sub, toggle: .remoteContent(allowed: true), hasArticleURL: true
        ))
    }

    func testStickyUpdateTreatsInheritAsDistinctFromAnExplicitChoice() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f")
        let update = FeedDetailPolicy.stickyUpdate(
            for: sub, toggle: .remoteContent(allowed: false), hasArticleURL: true
        )
        XCTAssertEqual(update?.defaultRemoteContent, .hide, "a toggle pins the feed even when the effect matches")
        XCTAssertNil(update?.defaultOpenMode)
        XCTAssertNil(update?.defaultStyling)
    }

    func testStickyUpdateNeverWritesOpenModeWithoutAnArticle() {
        let article = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: .article)
        // No link, so the reader shows the body; that must not revert the
        // "Article" default.
        XCTAssertNil(FeedDetailPolicy.stickyUpdate(
            for: article, toggle: .article(showing: false), hasArticleURL: false
        ))
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
    }
}
