import XCTest
import CabalmailKit
@testable import CabalmailUI

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

    // MARK: - What a scope opens with (#2144)

    func testASingleFeedScopeAnswersForItself() {
        let summary = RssSubscription(subscriptionId: "s", feedId: "f")
        let article = RssSubscription(subscriptionId: "a", feedId: "g", defaultOpenMode: .article)
        let subs = [summary, article]
        XCTAssertFalse(FeedDetailPolicy.opensArticle(in: .subscription("s"), folders: [], subscriptions: subs))
        XCTAssertTrue(FeedDetailPolicy.opensArticle(in: .subscription("a"), folders: [], subscriptions: subs))
    }

    /// A folder answers for every feed under it, its descendants' included —
    /// the rollup its badge counts already do.
    func testAFolderScopeAnswersForItsWholeSubtree() {
        let folders = [
            RssFolder(folderId: "tech", name: "Tech"),
            RssFolder(folderId: "langs", parentFolderId: "tech", name: "Languages"),
            RssFolder(folderId: "other", name: "Other")
        ]
        func sub(_ id: String, _ folder: String, _ mode: RssOpenMode) -> RssSubscription {
            RssSubscription(subscriptionId: id, feedId: id, folderId: folder, defaultOpenMode: mode)
        }
        let allArticle = [sub("a", "tech", .article), sub("b", "langs", .article),
                          sub("c", "other", .summary)]
        XCTAssertTrue(
            FeedDetailPolicy.opensArticle(in: .folder("tech"), folders: folders, subscriptions: allArticle),
            "a feed in a subfolder shares the folder's answer"
        )
        XCTAssertFalse(
            FeedDetailPolicy.opensArticle(in: .folder("other"), folders: folders, subscriptions: allArticle),
            "a sibling folder answers for its own feeds only"
        )
        // The load-bearing case: flip the descendant alone and the folder
        // stops agreeing, which is what makes the subtree walk the rule
        // rather than the top folder's own rows.
        let mixed = [sub("a", "tech", .article), sub("b", "langs", .summary)]
        XCTAssertFalse(
            FeedDetailPolicy.opensArticle(in: .folder("tech"), folders: folders, subscriptions: mixed)
        )
    }

    func testAllFeedsNeedsEveryFeedToAgree() {
        let article = RssSubscription(subscriptionId: "a", feedId: "a", defaultOpenMode: .article)
        let summary = RssSubscription(subscriptionId: "b", feedId: "b")
        XCTAssertTrue(FeedDetailPolicy.opensArticle(in: .all, folders: [], subscriptions: [article]))
        XCTAssertFalse(
            FeedDetailPolicy.opensArticle(in: .all, folders: [], subscriptions: [article, summary]),
            "with the open modes mixed the fuller stand-in set stands"
        )
    }

    /// Nothing to read is the fullest set, not an article answer — an empty
    /// scope, a scope whose feeds have not synced, and an unknown id all
    /// land here.
    func testAnEmptyScopeKeepsTheFullestStandIns() {
        XCTAssertFalse(FeedDetailPolicy.opensArticle(in: .all, folders: [], subscriptions: []))
        XCTAssertFalse(FeedDetailPolicy.opensArticle(in: .folder("gone"), folders: [], subscriptions: []))
        let article = RssSubscription(subscriptionId: "a", feedId: "a", defaultOpenMode: .article)
        XCTAssertFalse(
            FeedDetailPolicy.opensArticle(in: .subscription("missing"), folders: [], subscriptions: [article])
        )
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
