import XCTest
import CabalmailKit
@testable import Cabalmail

/// The scope-switch menu behind the feed list's title (cross-media plan,
/// Phase 1): All Feeds first, then the folder tree flattened depth-first
/// with each folder's subscriptions beneath it, indented per level, the
/// current scope checked wherever it sits. The feed sibling of
/// `FolderSwitchMenuPolicyTests`.
final class FeedScopeSwitchMenuPolicyTests: XCTestCase {
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

    private func rows(current: RssItemScope, title: String = "") -> [ReaderMenuRow<RssItemScope>] {
        FeedScopeSwitchMenuPolicy.rows(folders: folders, subscriptions: subs, current: current, currentTitle: title)
    }

    private static func stripped(_ label: String) -> String {
        label.replacingOccurrences(of: FeedScopeSwitchMenuPolicy.indentUnit, with: "")
    }

    func testAllFeedsLeadsThenTheTreeInSidebarOrder() {
        let rows = rows(current: .all)
        XCTAssertEqual(rows.map(\.option), [
            .all, .folder("art"), .folder("tech"), .folder("apple"), .subscription("s-df"),
            .subscription("s-rust"), .subscription("s-xkcd"),
        ])
        XCTAssertEqual(rows.map { Self.stripped($0.label) },
                       ["All Feeds", "Art", "Tech", "Apple", "Daring Fireball", "Rust Blog", "Comics!"])
    }

    /// Indentation follows the sidebar's depth: one em space per level, in
    /// the label, so an assistive client hears the nesting too.
    func testRowsAreIndentedOneStepPerLevel() {
        let rows = rows(current: .all)
        let depths = rows.map { row in
            row.label.prefix { String($0) == FeedScopeSwitchMenuPolicy.indentUnit }.count
        }
        XCTAssertEqual(depths, [0, 0, 0, 1, 2, 1, 0])
        XCTAssertEqual(FeedScopeSwitchMenuPolicy.label(title: "Apple", depth: 2), "\u{2003}\u{2003}Apple")
        XCTAssertEqual(FeedScopeSwitchMenuPolicy.label(title: "Art", depth: 0), "Art")
    }

    func testExactlyTheCurrentScopeIsChecked() {
        let rows = rows(current: .subscription("s-df"))
        XCTAssertEqual(rows.filter(\.isOn).map(\.option), [.subscription("s-df")])
        let folderRows = self.rows(current: .folder("tech"))
        XCTAssertEqual(folderRows.filter(\.isOn).map(\.option), [.folder("tech")])
        XCTAssertEqual(self.rows(current: .all).filter(\.isOn).map(\.option), [.all])
    }

    /// Before the catalog arrives the menu still shows the scope the list is
    /// on, checked, so the affordance never reads as empty — and All Feeds
    /// stays first.
    func testBeforeTheCatalogArrivesTheCurrentScopeIsStillOffered() {
        let rows = FeedScopeSwitchMenuPolicy.rows(folders: [], subscriptions: [],
                                                  current: .subscription("s-df"), currentTitle: "Daring Fireball")
        XCTAssertEqual(rows.map(\.option), [.all, .subscription("s-df")])
        XCTAssertEqual(rows.map(\.label), ["All Feeds", "Daring Fireball"])
        XCTAssertEqual(rows.filter(\.isOn).map(\.option), [.subscription("s-df")])
    }

    func testAllFeedsNeverGetsAPlaceholderRow() {
        let rows = FeedScopeSwitchMenuPolicy.rows(folders: [], subscriptions: [], current: .all,
                                                  currentTitle: "All Feeds")
        XCTAssertEqual(rows.map(\.option), [.all])
        XCTAssertTrue(rows[0].isOn)
    }

    func testAScopeMissingFromTheCatalogIsStillOfferedOnce() {
        let rows = rows(current: .folder("gone"), title: "Gone")
        XCTAssertEqual(rows.filter { $0.option == .folder("gone") }.count, 1)
        XCTAssertEqual(rows.filter(\.isOn).map(\.label), ["Gone"])
        XCTAssertEqual(rows[1].option, .folder("gone"), "right under All Feeds")
    }

    func testKeysAreStableAcrossWhatTheRowDraws() {
        let checked = rows(current: .folder("tech"))
        let unchecked = rows(current: .all)
        XCTAssertEqual(checked.map(\.key), unchecked.map(\.key))
        XCTAssertEqual(checked[0].key, "scope.all")
        XCTAssertEqual(checked[2].key, "scope.folder:tech")
        XCTAssertEqual(checked[4].key, "scope.sub:s-df")
    }

    func testSymbolsFollowTheSidebar() {
        XCTAssertEqual(FeedScopeSwitchMenuPolicy.symbol(for: .all), "folder")
        XCTAssertEqual(FeedScopeSwitchMenuPolicy.symbol(for: .folder("tech")), "folder")
        XCTAssertEqual(FeedScopeSwitchMenuPolicy.symbol(for: .subscription("s-df")), "dot.radiowaves.up.forward")
    }

    func testIdentityChangesWhenTheCheckedScopeDoes() {
        XCTAssertNotEqual(
            FeedScopeSwitchMenuPolicy.identity(rows(current: .all)),
            FeedScopeSwitchMenuPolicy.identity(rows(current: .folder("tech")))
        )
    }

    func testIdentityChangesWhenTheCatalogArrives() {
        let before = FeedScopeSwitchMenuPolicy.rows(folders: [], subscriptions: [], current: .all,
                                                    currentTitle: "All Feeds")
        XCTAssertNotEqual(
            FeedScopeSwitchMenuPolicy.identity(before),
            FeedScopeSwitchMenuPolicy.identity(rows(current: .all))
        )
    }

    func testIdentityIsStableForTheSameRows() {
        XCTAssertEqual(
            FeedScopeSwitchMenuPolicy.identity(rows(current: .all)),
            FeedScopeSwitchMenuPolicy.identity(rows(current: .all))
        )
    }
}
