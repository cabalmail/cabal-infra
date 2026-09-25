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

    /// The sidebar's Unread pill: feeds with unread, folders with unread
    /// under them, nothing else — and the open scope stays regardless.
    func testUnreadOnlyKeepsOnlyRowsWithUnreadUnderThem() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-df": 5], collapsed: [], unreadOnly: true)
        XCTAssertEqual(rows.map(\.title), ["Tech", "Apple", "Daring Fireball"],
                       "Art, Rust Blog and Comics! have nothing unread; Tech shows only because Apple does")
    }

    func testUnreadOnlyExemptsTheOpenScopeAndItsAncestors() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs, unreadCounts: [:],
                                        collapsed: [], unreadOnly: true, keep: .subscription("s-df"))
        XCTAssertEqual(rows.map(\.title), ["Tech", "Apple", "Daring Fireball"],
                       "reading the last unread item must not pull the open feed out of the sidebar")
        let folderRows = FeedSidebarRows.rows(folders: folders, subscriptions: subs, unreadCounts: [:],
                                              collapsed: [], unreadOnly: true, keep: .folder("apple"))
        XCTAssertEqual(folderRows.map(\.title), ["Tech", "Apple"],
                       "a kept folder brings its ancestors, not its caught-up contents")
    }

    func testUnreadOnlyStillHonoursCollapse() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-df": 5], collapsed: ["tech"], unreadOnly: true)
        XCTAssertEqual(rows.map(\.title), ["Tech"],
                       "the pill is a standing mode, not a search — a collapsed folder stays collapsed")
    }

    func testUnreadOnlyAndTextFilterCombine() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-df": 5, "s-rust": 1], collapsed: [],
                                        filter: "rust", unreadOnly: true)
        XCTAssertEqual(rows.map(\.title), ["Tech", "Rust Blog"])
    }

    func testTotalUnread() {
        XCTAssertEqual(FeedSidebarRows.totalUnread(["a": 2, "b": 3]), 5)
        XCTAssertEqual(FeedSidebarRows.totalUnread([:]), 0)
    }

    // MARK: - Totals (cross-media plan, Phase 1)

    /// The cached item count rolls up a folder tree exactly as unread does,
    /// so a folder badge can read "unread / total" like a mail folder's.
    func testTotalsRollUpLikeUnread() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-rust": 2, "s-df": 5],
                                        totalCounts: ["s-rust": 40, "s-df": 25, "s-xkcd": 9], collapsed: [])
        XCTAssertEqual(rows.map(\.title), ["Art", "Tech", "Apple", "Daring Fireball", "Rust Blog", "Comics!"])
        XCTAssertEqual(rows.map(\.unread), [0, 7, 5, 5, 2, 0])
        XCTAssertEqual(rows.map(\.total), [0, 65, 25, 25, 40, 9])
    }

    /// Callers that have no totals yet (or never will) get zero, not a crash
    /// or a stale number: the badge then hides under the total modes.
    func testTotalsDefaultToZeroWhenNotSupplied() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs,
                                        unreadCounts: ["s-df": 5], collapsed: [])
        XCTAssertTrue(rows.allSatisfy { $0.total == 0 })
    }

    func testCollapseKeepsTheTotalRollUp() {
        let rows = FeedSidebarRows.rows(folders: folders, subscriptions: subs, unreadCounts: [:],
                                        totalCounts: ["s-df": 25, "s-rust": 40], collapsed: ["tech"])
        XCTAssertEqual(rows.map(\.title), ["Art", "Tech", "Comics!"])
        XCTAssertEqual(rows[1].total, 65)
    }

    func testGrandTotalAndTheAllFeedsRowCarryIt() {
        XCTAssertEqual(FeedSidebarRows.grandTotal(["a": 2, "b": 3]), 5)
        XCTAssertEqual(FeedSidebarRows.grandTotal([:]), 0)
        let row = FeedSidebarRows.allFeedsRow(unread: 3, total: 12)
        XCTAssertEqual(row.unread, 3)
        XCTAssertEqual(row.total, 12)
    }

    /// #1548: the row both sidebars head their list with. Its identity is a
    /// folder so the shared row label draws it exactly like the folder rows
    /// beneath it — that sameness is the fix.
    func testAllFeedsRowMatchesTheShapeOfAFolderRow() {
        let row = FeedSidebarRows.allFeedsRow(unread: 7)
        XCTAssertEqual(row.title, "All Feeds")
        XCTAssertEqual(row.unread, 7)
        XCTAssertEqual(row.depth, 0, "it heads the list, so it is never indented")
        XCTAssertFalse(row.hasChildren, "no chevron: its scope is not expandable")
        guard case .folder = row.kind else {
            return XCTFail("a subscription row draws a different icon than its folder siblings")
        }
    }

    /// The total is the row's whole content, so a zero has to survive as a
    /// zero — the label drops the count rather than drawing an empty capsule.
    func testAllFeedsRowCarriesTheUnreadTotalItIsGiven() {
        XCTAssertEqual(FeedSidebarRows.allFeedsRow(unread: 0).unread, 0)
        XCTAssertEqual(
            FeedSidebarRows.allFeedsRow(unread: FeedSidebarRows.totalUnread(["a": 2, "b": 5])).unread,
            7
        )
    }
}
