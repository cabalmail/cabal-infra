import XCTest
import CabalmailKit
@testable import Cabalmail

/// Multi-feed rows name the feed: the subscription's title when the catalog
/// knows it, the article's host as the fallback, nothing when neither helps.
final class FeedItemLabelsTests: XCTestCase {
    private func item(subscription: String, url: String) -> RssItem {
        RssItem(feedId: "f", subscriptionId: subscription, itemId: "i", sortKey: "k", url: url)
    }

    func testTitleWinsOverHost() {
        let titles = ["sub-1": "Daring Fireball"]
        XCTAssertEqual(FeedItemLabels.feedName(for: item(subscription: "sub-1", url: "https://daringfireball.net/x"),
                                               titles: titles), "Daring Fireball")
    }

    func testHostWhenTheTitleIsUnknownOrEmpty() {
        XCTAssertEqual(FeedItemLabels.feedName(for: item(subscription: "sub-2", url: "https://xkcd.com/1"),
                                               titles: ["sub-2": ""]), "xkcd.com")
        XCTAssertEqual(FeedItemLabels.feedName(for: item(subscription: "sub-3", url: "https://xkcd.com/1"),
                                               titles: [:]), "xkcd.com")
    }

    func testNothingWhenThereIsNoUsableURL() {
        XCTAssertEqual(FeedItemLabels.feedName(for: item(subscription: "sub-4", url: ""), titles: [:]), "")
    }
}
