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
            let wide = FeedReaderToolbarLayout.wideBar(
                showingArticle: state.showingArticle, hasArticle: state.hasArticle
            )
            let offBar = wide.filter { !FeedReaderToolbarLayout.menuBar.contains($0) && $0 != .more }
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

    /// Today's wide bar, state by state: Remote content only while the
    /// feed's own content shows, Open article and More only with a link.
    func testTheWideBarPerState() {
        XCTAssertEqual(
            FeedReaderToolbarLayout.wideBar(showingArticle: false, hasArticle: false),
            [.read, .favorite, .readerMode, .remoteContent]
        )
        XCTAssertEqual(
            FeedReaderToolbarLayout.wideBar(showingArticle: false, hasArticle: true),
            [.read, .favorite, .readerMode, .remoteContent, .article, .more]
        )
        XCTAssertEqual(
            FeedReaderToolbarLayout.wideBar(showingArticle: true, hasArticle: true),
            [.read, .favorite, .readerMode, .article, .more]
        )
    }

    /// The More menu on the wide bar carries the link rows only; the rest
    /// are bar items there.
    func testTheWideMoreMenuIsTheLinkRows() {
        XCTAssertEqual(FeedReaderToolbarLayout.moreMenu, [.openInBrowser, .shareLink, .copyLink])
    }

    // MARK: - Stand-ins

    /// A summary-opening scope reserves the fullest wide bar, in its order,
    /// so the six slots are where an opened item's buttons land.
    func testTheSummaryStandInsAreTheFullestWideBar() {
        XCTAssertEqual(FeedReaderToolbarLayout.standIns(showingArticle: false), FeedReaderAction.allCases)
        for state in Self.states {
            let wide = FeedReaderToolbarLayout.wideBar(
                showingArticle: state.showingArticle, hasArticle: state.hasArticle
            )
            XCTAssertTrue(
                wide.allSatisfy(FeedReaderToolbarLayout.standIns(showingArticle: false).contains),
                "\(wide) has an action the stand-ins don't reserve"
            )
        }
    }

    /// #2144: an article-opening scope must not reserve Remote content. It
    /// sits in the middle of the bar, so an item that does not draw it moves
    /// every slot after it — Open article and More, measured 42 pt left.
    func testAnArticleOpeningScopeReservesNoRemoteContentSlot() {
        let standIns = FeedReaderToolbarLayout.standIns(showingArticle: true)
        XCTAssertEqual(standIns, [.read, .favorite, .readerMode, .article, .more])
        XCTAssertFalse(standIns.contains(.remoteContent))
    }

    /// The invariant the two halves of the fix exist for: whatever a scope's
    /// saved open mode is, the stand-in row and the bar the first item opened
    /// in that scope draws are the SAME list, so no slot index moves as the
    /// item opens. Pinned through the shipping policy on both sides.
    func testTheStandInsMatchTheBarAnItemOpenedInTheScopeDraws() {
        for mode in [RssOpenMode.summary, .article] {
            let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: mode)
            let standIns = FeedReaderToolbarLayout.standIns(
                showingArticle: FeedDetailPolicy.opensArticle(
                    in: .subscription("s"), folders: [], subscriptions: [sub]
                )
            )
            let live = FeedReaderToolbarLayout.wideBar(
                showingArticle: FeedDetailPolicy.initial(for: sub, hasArticleURL: true).showsArticle,
                hasArticle: true
            )
            XCTAssertEqual(standIns, live, "a \(mode.rawValue) feed's stand-ins are not the bar it opens with")
            for (slot, action) in live.enumerated() {
                XCTAssertEqual(
                    standIns.firstIndex(of: action), slot,
                    "\(action.rawValue) changes slot as a \(mode.rawValue) feed's item opens"
                )
            }
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
