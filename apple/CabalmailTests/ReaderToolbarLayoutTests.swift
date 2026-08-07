import XCTest
@testable import Cabalmail

// Regression coverage for issue #911: the reader's bottom bar carried seven
// items, which the iOS 27 SDK no longer draws — it folded the tail into its
// own overflow control, so Reader view and Archive vanished, and inside Trash
// that took Delete Forever (the only permanent-delete affordance in the app)
// with it. The bar's budget now lives in `ReaderToolbarLayout` rather than in
// a comment, so a future item can't quietly re-fill it.
final class ReaderToolbarLayoutTests: XCTestCase {

    func testBottomBarStaysWithinCapacity() {
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let actions = ReaderToolbarLayout.bottomBar(leading: leading)
            XCTAssertLessThanOrEqual(
                actions.count,
                ReaderToolbarLayout.capacity,
                "\(leading) bar draws \(actions.count) items; past \(ReaderToolbarLayout.capacity) "
                + "the system compacts the tail into an overflow of its own"
            )
        }
    }

    func testDisposeAndOverflowStayOnTheBar() {
        // Dispose is Archive/Delete outside Trash and Delete Forever inside it;
        // the overflow menu carries everything the bar gave up. Neither may be
        // the item that gets demoted.
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let actions = ReaderToolbarLayout.bottomBar(leading: leading)
            XCTAssertTrue(actions.contains(.dispose), "\(leading) bar must keep dispose")
            XCTAssertTrue(actions.contains(.overflow), "\(leading) bar must keep the overflow menu")
        }
    }

    func testLeadingSlotSwapsRatherThanAdds() {
        let reply = ReaderToolbarLayout.bottomBar(leading: .reply)
        let draft = ReaderToolbarLayout.bottomBar(leading: .editDraft)

        XCTAssertEqual(reply.count, draft.count, "Drafts swaps the leading slot, it doesn't add one")
        XCTAssertEqual(reply.first, .reply)
        XCTAssertEqual(draft.first, .editDraft)
        XCTAssertFalse(draft.contains(.reply), "Edit Draft replaces Reply rather than joining it")
    }

    func testDemotedActionsAreOffTheBar() {
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let actions = ReaderToolbarLayout.bottomBar(leading: leading)
            for demoted in ReaderToolbarLayout.demotedToOverflow {
                XCTAssertFalse(
                    actions.contains(demoted),
                    "\(demoted.rawValue) rides in the overflow menu, not the \(leading) bar"
                )
            }
        }
    }

    // Regression coverage for issue #923: at regular width on iOS 27 a
    // `.bottomBar` group attaches to the window rather than the split view's
    // detail column, spreading the reader's actions under the message list.
    // The reader draws its own pane-scoped bar there, and only there — iOS 26
    // and compact width keep the system bar.
    func testRegularWidthOnOS27DrawsItsOwnBar() {
        XCTAssertTrue(
            ReaderToolbarLayout.usesOwnActionBar(isRegularWidth: true, isOS27OrLater: true),
            "iPad-regular on iOS 27 must pin the actions to the reading pane"
        )
    }

    func testSystemBarIsKeptEverywhereElse() {
        for (regular, os27) in [(true, false), (false, true), (false, false)] {
            XCTAssertFalse(
                ReaderToolbarLayout.usesOwnActionBar(isRegularWidth: regular, isOS27OrLater: os27),
                "regular=\(regular) os27=\(os27) must keep the system bottom bar"
            )
        }
    }

    // The pane-scoped bar's width-adaptive item set (the Notes half of #923):
    // `capacity` was measured against the 402pt iPhone system bar, but the
    // reader's own bar never compacts and knows its pane's real width — which
    // the user can change by dragging the iPad split divider — so the demoted
    // toggles return whenever there's room and leave again as the pane
    // narrows.
    func testOwnBarPromotesDemotedTogglesWhenWide() {
        for leading in [LeadingReaderAction.reply, .editDraft] {
            let actions = ReaderToolbarLayout.ownBar(
                leading: leading,
                paneWidth: ReaderToolbarLayout.fullSetMinWidth
            )
            for demoted in ReaderToolbarLayout.demotedToOverflow {
                XCTAssertTrue(
                    actions.contains(demoted),
                    "\(demoted.rawValue) must rejoin the \(leading) bar when the pane has room"
                )
            }
        }
    }

    func testOwnBarMatchesSystemBarWhenNarrow() {
        for leading in [LeadingReaderAction.reply, .editDraft] {
            XCTAssertEqual(
                ReaderToolbarLayout.ownBar(
                    leading: leading,
                    paneWidth: ReaderToolbarLayout.fullSetMinWidth - 1
                ),
                ReaderToolbarLayout.bottomBar(leading: leading),
                "a narrow pane draws the same compact set as the system bar"
            )
        }
    }

    func testOwnBarKeepsEndpointsStableAcrossResizes() {
        // Promotion grows the middle of the bar: Reply keeps the leading edge
        // and dispose/overflow the trailing one at every width, so dragging
        // the split divider never relocates those hit targets.
        for width in [CGFloat(0), 402, ReaderToolbarLayout.fullSetMinWidth, 825] {
            let actions = ReaderToolbarLayout.ownBar(leading: .reply, paneWidth: width)
            XCTAssertEqual(actions.first, .reply, "Reply leads at width \(width)")
            XCTAssertEqual(
                Array(actions.suffix(2)),
                [.dispose, .overflow],
                "dispose and overflow trail at width \(width)"
            )
        }
    }

    func testEveryActionIsStillReachable() {
        // Demoting must not drop an action on the floor: every case is either
        // drawn on the bar (in one of the two leading configurations) or
        // carried by the overflow menu.
        let reachable = Set(ReaderToolbarLayout.bottomBar(leading: .reply))
            .union(ReaderToolbarLayout.bottomBar(leading: .editDraft))
            .union(ReaderToolbarLayout.demotedToOverflow)

        XCTAssertEqual(
            reachable,
            Set(ReaderToolbarAction.allCases),
            "every reader action must be on the bar or in the overflow menu"
        )
    }
}
