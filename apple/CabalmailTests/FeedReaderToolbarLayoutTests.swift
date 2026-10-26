import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the feed reader's bar draws (`FeedReaderToolbarLayout`), in both of
/// its shapes, and the macOS stand-ins that hold its place. The budgets are
/// `ReaderToolbarPolicy`'s, shared with the mail reader.
final class FeedReaderToolbarLayoutTests: XCTestCase {

    private static let states: [(showingArticle: Bool, hasArticle: Bool)] = [
        (false, false), (false, true), (true, true)
    ]

    // MARK: - Touch top bar

    /// Read, Flag and the View menu: three items, inside the top bar's
    /// budget with room for the title.
    func testTheTouchBarIsReadFlagAndTheViewMenu() {
        XCTAssertEqual(FeedReaderToolbarLayout.menuBar, [.read, .favorite, .more])
        XCTAssertLessThanOrEqual(FeedReaderToolbarLayout.menuBar.count, ReaderToolbarPolicy.topBarCapacity)
    }

    /// Everything the touch bar leaves out is in the View menu whenever it
    /// applies, so no action is out of reach on iPhone.
    func testTheViewMenuCarriesWhatTheTouchBarLeavesOut() {
        for state in Self.states {
            let rows = FeedReaderToolbarLayout.viewMenu(
                showingArticle: state.showingArticle, hasArticle: state.hasArticle
            ).flatMap { $0 }
            let wide = FeedReaderToolbarLayout.wideBar(hasArticle: state.hasArticle)
            // Remote content keeps its wide-bar slot while the article shows
            // but is disabled there (#2206); the touch menu leaves it out.
            let offBar = wide.filter {
                !FeedReaderToolbarLayout.menuBar.contains($0) && $0 != .more
                    && !(state.showingArticle && $0 == .remoteContent)
            }
            for action in offBar {
                XCTAssertTrue(rows.contains(Self.menuItem(for: action)), "\(action) has no touch route in \(state)")
            }
        }
    }

    /// Today's View menu: Reader view, then Remote content while the feed's
    /// own content shows; then, for an item with a link, a divider and the
    /// article and link rows.
    func testTheViewMenuRowsAndSections() {
        XCTAssertEqual(
            FeedReaderToolbarLayout.viewMenu(showingArticle: false, hasArticle: false),
            [[.readerMode, .remoteContent]]
        )
        XCTAssertEqual(
            FeedReaderToolbarLayout.viewMenu(showingArticle: false, hasArticle: true),
            [[.readerMode, .remoteContent], [.article, .openInBrowser, .shareLink, .copyLink]]
        )
        XCTAssertEqual(
            FeedReaderToolbarLayout.viewMenu(showingArticle: true, hasArticle: true),
            [[.readerMode], [.article, .openInBrowser, .shareLink, .copyLink]]
        )
    }

    // MARK: - Wide bar (macOS, visionOS)

    /// Today's wide bar: Read, Flag, Reader view and Remote content always,
    /// Open article and More only with a link.
    func testTheWideBarPerState() {
        XCTAssertEqual(
            FeedReaderToolbarLayout.wideBar(hasArticle: false),
            [.read, .favorite, .readerMode, .remoteContent]
        )
        XCTAssertEqual(
            FeedReaderToolbarLayout.wideBar(hasArticle: true),
            [.read, .favorite, .readerMode, .remoteContent, .article, .more]
        )
    }

    /// #2206: pressing Open article (or Show feed content) flips what the
    /// open item shows, and nothing in the bar may change slot under the
    /// pointer that pressed it. The wide bar used to drop Remote content
    /// from the middle while the article showed, which moved Open article
    /// and More 42 pt left, so a second click at the same point opened More.
    /// The bar no longer takes what the item shows, so the toggle cannot
    /// change it; this pins the slots the pointer is over: Remote content
    /// held in the middle, Open article and More after it.
    func testTogglingTheArticleMovesNoSlot() {
        let bar = FeedReaderToolbarLayout.wideBar(hasArticle: true)
        XCTAssertEqual(bar.firstIndex(of: .remoteContent), 3)
        XCTAssertEqual(bar.firstIndex(of: .article), 4)
        XCTAssertEqual(bar.firstIndex(of: .more), 5)
    }

    /// The kept slot is disabled while the publisher's page shows, which
    /// loads its own remote content, and with no feed content to act on.
    func testRemoteContentIsDisabledWhileTheArticleShows() {
        XCTAssertTrue(FeedReaderToolbarLayout.remoteContentEnabled(showingArticle: false, hasFeedContent: true))
        XCTAssertFalse(FeedReaderToolbarLayout.remoteContentEnabled(showingArticle: true, hasFeedContent: true))
        XCTAssertFalse(FeedReaderToolbarLayout.remoteContentEnabled(showingArticle: false, hasFeedContent: false))
        XCTAssertFalse(FeedReaderToolbarLayout.remoteContentEnabled(showingArticle: true, hasFeedContent: false))
    }

    /// The More menu on the wide bar carries the link rows only; the rest
    /// are bar items there.
    func testTheWideMoreMenuIsTheLinkRows() {
        XCTAssertEqual(FeedReaderToolbarLayout.moreMenu, [.openInBrowser, .shareLink, .copyLink])
    }

    // MARK: - Stand-ins

    /// The stand-ins are the fullest wide bar, in its order, so the six
    /// slots are where an opened item's buttons land.
    func testTheStandInsAreTheFullestWideBar() {
        XCTAssertEqual(FeedReaderToolbarLayout.standIns(), FeedReaderAction.allCases)
        for state in Self.states {
            let wide = FeedReaderToolbarLayout.wideBar(hasArticle: state.hasArticle)
            XCTAssertTrue(
                wide.allSatisfy(FeedReaderToolbarLayout.standIns().contains),
                "\(wide) has an action the stand-ins don't reserve"
            )
        }
    }

    /// #2144's invariant, which no longer needs the scope's saved open mode:
    /// whatever a feed opens with, the stand-in row and the bar its first
    /// item draws are the SAME list, so no slot index moves as it opens.
    /// Pinned through the shipping policy on the live side.
    func testTheStandInsMatchTheBarAnItemOpenedInTheScopeDraws() {
        for mode in [RssOpenMode.summary, .article] {
            let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: mode)
            let opened = FeedDetailPolicy.initial(for: sub, hasArticleURL: true)
            XCTAssertEqual(
                opened.showsArticle, mode == .article,
                "the policy no longer opens a \(mode.rawValue) feed as itself"
            )
            let live = FeedReaderToolbarLayout.wideBar(hasArticle: true)
            XCTAssertEqual(
                FeedReaderToolbarLayout.standIns(), live,
                "a \(mode.rawValue) feed's stand-ins are not the bar it opens with"
            )
        }
    }

    private static func menuItem(for action: FeedReaderAction) -> FeedReaderMenuItem {
        switch action {
        case .readerMode: return .readerMode
        case .remoteContent: return .remoteContent
        case .article: return .article
        case .read, .favorite, .more:
            XCTFail("\(action) is not a menu row")
            return .copyLink
        }
    }
}
