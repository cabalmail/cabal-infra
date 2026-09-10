import XCTest
import CabalmailKit
@testable import Cabalmail

/// The Feeds sidebar's tree rules (RSS plan, phase 5b): folder order,
/// nesting, collapse, unread roll-up, and the filter.
@MainActor
final class FeedSidebarRowsTests: XCTestCase {
    private let folders = [
        RssFolder(folderId: "tech", name: "Tech", displayOrder: 1),
        RssFolder(folderId: "apple", parentFolderId: "tech", name: "Apple"),
        RssFolder(folderId: "art", name: "Art", displayOrder: 0),
    ]
    private let subs = [
        RssSubscription(subscriptionId: "s-rust", feedId: "f1", folderId: "tech",
                        feed: RssFeedSummary(feedId: "f1", title: "Rust Blog")),
        RssSubscription(subscriptionId: "s-df", feedId: "f2", folderId: "apple",
                        feed: RssFeedSummary(feedId: "f2", title: "Daring Fireball")),
        RssSubscription(subscriptionId: "s-xkcd", feedId: "f3", customTitle: "Comics!",
                        feed: RssFeedSummary(feedId: "f3", title: "xkcd.com")),
    ]

    func testOrderNestingAndUnreadRollUp() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-rust": 2, "s-df": 5, "s-xkcd": 1], collapsed: [])
        XCTAssertEqual(rows.map(\.title), ["Art", "Tech", "Apple", "Daring Fireball", "Rust Blog", "Comics!"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2, 1, 0])
        XCTAssertEqual(rows.map(\.unread), [0, 7, 5, 5, 2, 1])
        XCTAssertEqual(rows[1].hasChildren, true)
        XCTAssertEqual(rows[0].hasChildren, false)
        XCTAssertEqual(rows[3].scope, .subscription("s-df"))
        XCTAssertEqual(rows[2].scope, .folder("apple"))
    }

    func testCollapseHidesDescendantsButKeepsRollUp() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-df": 5], collapsed: ["tech"])
        XCTAssertEqual(rows.map(\.title), ["Art", "Tech", "Comics!"])
        XCTAssertEqual(rows[1].unread, 5)
    }

    func testFilterShowsMatchesAndTheirAncestorsOnly() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs, unreadCounts: [:],
                                        collapsed: ["tech"], filter: "fire")
        // The filter overrides collapse so the match is reachable.
        XCTAssertEqual(rows.map(\.title), ["Tech", "Apple", "Daring Fireball"])
        XCTAssertEqual(FeedSidebarRows.rows(folders: folders, subscriptions: subs, unreadCounts: [:],
                                            collapsed: [], filter: "zzz"), [])
    }

    func testTotalUnread() {
        XCTAssertEqual(FeedSidebarRows.totalUnread(["a": 2, "b": 3]), 5)
        XCTAssertEqual(FeedSidebarRows.totalUnread([:]), 0)
    }
}
