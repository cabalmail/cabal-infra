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
