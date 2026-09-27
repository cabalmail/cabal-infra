import XCTest
@testable import Cabalmail

// Regression coverage for issue #984: the macOS message-list column declared no
// width, so macOS 27 sized it from the list's own ideal and charged the
// neighbours. Measured on the 27 client, the sidebar sat at exactly its declared
// minimum — the only thing protecting it — while the reading pane, which
// declared no floor at all, absorbed every resize on its own: the list froze at
// its launch width and the reader shrank without limit. In the tester's 1500pt
// window that left a 1275pt list against a 45pt reader; shrinking a window with
// the list frozen at 658pt drove the reader to 60pt. A reader that narrow reads
// as broken rather than cramped — selecting a message visibly does nothing,
// because there is nowhere for the message to appear, which is how the issue was
// first reported.
final class ListColumnWidthTests: XCTestCase {

    /// Widths measured on macOS 27 from stage `aaf39bd4`: the window the tester
    /// drove, and the list column that had frozen inside it.
    private let observedWindowWidth: CGFloat = 1500
    private let observedListWidth: CGFloat = 1275
    /// The narrowest window worth defending. Below this the split has to
    /// overflow somewhere whatever the policy says.
    private let smallestSupportedWindow: CGFloat = 900

    /// What the reading pane is left once the sidebar and list have taken theirs.
    private func readerWidth(inWindowOfWidth window: CGFloat, listWidth: CGFloat) -> CGFloat {
        window - SidebarColumnWidth.ideal - listWidth
    }

    // macOS 27 gives the content column everything up to its maximum, so the cap
    // — not `ideal` — is the width a launch actually comes up at there. Both
    // have to leave a readable reader.
    func testTheLaunchWidthLeavesTheReadingPaneUsable() {
        for listWidth in [
            ListColumnWidth.ideal,
            ListColumnWidth.bounds(
                splitWidth: observedWindowWidth,
                sidebarWidth: SidebarColumnWidth.ideal
            ).maximum
        ] {
            XCTAssertGreaterThanOrEqual(
                readerWidth(inWindowOfWidth: observedWindowWidth, listWidth: listWidth),
                ListColumnWidth.readerFloor,
                "a launch has to open with a reader wide enough to show a message"
            )
        }
    }

    // The reader is the point of the window, so the list can't claim most of it
    // however much room there is — the failure being fixed is exactly a list
    // that grew until the reader had nothing.
    func testTheListNeverClaimsMostOfAWideWindow() {
        let wideWindow: CGFloat = 2900
        let cap = ListColumnWidth.bounds(
            splitWidth: wideWindow,
            sidebarWidth: SidebarColumnWidth.ideal
        ).maximum
        XCTAssertLessThan(cap, wideWindow / 2)
        XCTAssertGreaterThan(
            readerWidth(inWindowOfWidth: wideWindow, listWidth: cap),
            cap,
            "the reader gets the larger share of a window with room for both"
        )
    }

    // The width the old, policy-free column froze at is the one the fix has to
    // rule out: it is what left the reader too narrow to render anything.
    func testTheWidthTheColumnFrozeAtIsNowOutOfBounds() {
        let cap = ListColumnWidth.bounds(
            splitWidth: observedWindowWidth,
            sidebarWidth: SidebarColumnWidth.ideal
        ).maximum
        XCTAssertLessThan(cap, observedListWidth)
        XCTAssertGreaterThanOrEqual(
            readerWidth(inWindowOfWidth: observedWindowWidth, listWidth: cap),
            ListColumnWidth.readerFloor,
            "even a list widened to its cap has to leave the reader its floor"
        )
    }

    // Shrinking the window used to come out of the reading pane alone, because
    // the list had no maximum to be pulled back to and no minimum to shrink
    // toward. A 900pt window can't seat sidebar + list + reader at their
    // preferred widths, so the list has to give ground rather than sit at the
    // width a wider launch left it.
    func testShrinkingTheWindowTakesWidthFromTheListNotOnlyTheReader() {
        let cap = ListColumnWidth.bounds(
            splitWidth: smallestSupportedWindow,
            sidebarWidth: SidebarColumnWidth.ideal
        ).maximum
        XCTAssertLessThanOrEqual(cap, ListColumnWidth.ideal)
        // Re-pointed by #1014, not weakened: the cap used to be clamped *up* to
        // `minimum` in a window this narrow, which is precisely what left the
        // column with no travel. `squeezedMinimum` is the floor such a window
        // squeezes the list to instead.
        XCTAssertGreaterThanOrEqual(cap, ListColumnWidth.squeezedMinimum)
        // 60pt was the measured failure; the cap has to do far better than that
        // even in the window that can least afford all three columns.
        XCTAssertGreaterThan(
            readerWidth(inWindowOfWidth: smallestSupportedWindow, listWidth: cap),
            ListColumnWidth.readerFloor / 2
        )
    }

    // A window too narrow for sidebar + list + reader can't satisfy everyone;
    // the list must still be given a positive, ordered range rather than a
    // negative width. (Before #1014 this asserted the cap was clamped up to
    // `minimum` — the clamp that collapsed the range; the property that
    // mattered was that the arithmetic never went negative.)
    func testAnImpossiblyNarrowWindowStillReportsAUsableRange() {
        let bounds = ListColumnWidth.bounds(splitWidth: 400,
                                            sidebarWidth: SidebarColumnWidth.ideal)
        XCTAssertEqual(bounds.minimum, ListColumnWidth.squeezedMinimum)
        XCTAssertEqual(bounds.maximum, bounds.minimum + ListColumnWidth.minimumTravel)
    }

    // `.onGeometryChange` hasn't fired when the column is first built. A cap
    // derived from that zero width would pin the column to its floor for the
    // first layout and flick it wider a frame later.
    func testThePreLayoutMeasurementOpensAtTheIdealWidth() {
        let bounds = ListColumnWidth.bounds(splitWidth: 0,
                                            sidebarWidth: SidebarColumnWidth.ideal)
        XCTAssertEqual(bounds.maximum, ListColumnWidth.ideal)
        XCTAssertEqual(bounds.minimum, ListColumnWidth.minimum)
    }

    func testTheBoundsAreOrdered() {
        XCTAssertLessThan(ListColumnWidth.minimum, ListColumnWidth.ideal)
        XCTAssertLessThan(ListColumnWidth.squeezedMinimum, ListColumnWidth.minimum)
    }

    // MARK: - Issue #1014

    // The invariant behind the report: a column whose floor equals its ceiling
    // has no travel, and the divider then silently retargets the sidebar. The
    // tester measured exactly zero travel at 880 and 900 across six drags.
    func testTheDividerKeepsTravelAtEveryWindowWidth() {
        for window in stride(from: CGFloat(400), through: 3000, by: 20) {
            let bounds = ListColumnWidth.bounds(splitWidth: window,
                                                sidebarWidth: SidebarColumnWidth.ideal)
            XCTAssertGreaterThanOrEqual(
                bounds.maximum - bounds.minimum,
                ListColumnWidth.minimumTravel,
                "the list/reader divider has nowhere to travel in a \(window)pt window"
            )
        }
    }

    // The widths the tester drove (#1014): the list column was frozen at 300pt
    // in both directions in every window at or below ~920pt.
    func testTheMeasuredFrozenWindowsAreNoLongerFrozen() {
        for window in [CGFloat(880), 900, 920] {
            let bounds = ListColumnWidth.bounds(splitWidth: window,
                                                sidebarWidth: SidebarColumnWidth.ideal)
            XCTAssertGreaterThan(bounds.maximum, bounds.minimum, "frozen at \(window)pt")
        }
    }

    // How the travel is bought matters: by lowering the floor, never by raising
    // the ceiling into the reading pane's floor. #984 ruled the reader the point
    // of the window, and the whole complaint in #1014 is that a drag ended up
    // costing the reader width — so the cap in a cramped window must not exceed
    // the width the frozen column already claimed.
    func testTheTravelIsNeverBoughtFromTheReadingPane() {
        for window in stride(from: CGFloat(400), through: 3000, by: 20) {
            let bounds = ListColumnWidth.bounds(splitWidth: window,
                                                sidebarWidth: SidebarColumnWidth.ideal)
            XCTAssertLessThanOrEqual(
                bounds.maximum, shippedCap(inWindowOfWidth: window),
                "a \(window)pt window lets the list widen past the width it could before"
            )
        }
    }

    /// The cap the shipped (#1007) policy reported: the list's share of the
    /// window, clamped *up* to `minimum` — the clamp that collapsed the range.
    private func shippedCap(inWindowOfWidth window: CGFloat) -> CGFloat {
        max(ListColumnWidth.minimum,
            min(window * ListColumnWidth.maximumWindowShare,
                window - SidebarColumnWidth.ideal - ListColumnWidth.readerFloor))
    }

    // MARK: - Issue #1716

    // Where the column is PINNED rather than bounded (regular-width iPad and
    // visionOS), the old ceiling was `splitWidth - readerFloor`: pinned width
    // plus the reader's declared floor summed to exactly the window. UIKit
    // resolves that fit at launch but drops the primary column when it
    // re-resolves it during a resize, which left the reported window holding
    // only the reader's placeholder — zero controls on screen, the folder panel
    // parked at negative x, and no way back from inside the window.
    //
    // The band is not a pair of magic widths. It is every width where the clamp
    // is active, i.e. `[regular-width floor, readerFloor + stored)` — which is
    // why the tester's sweep broke at 700 and 725 but not at 749 or 834, where
    // the stored width sat under the cap and the reader kept 11 and 96pt.

    /// Widths the sweep drove, and the stored column width solved out of it
    /// (700 → 340, 714 → 354 clamped; 834 → 378 unclamped, so 378 is stored).
    private let storedWidthBehindTheSweep: CGFloat = 378
    private let brokenSweepWidths: [CGFloat] = [700, 725]
    /// Slack measured surviving the same resize transition that 0pt failed: the
    /// sweep's 749pt row, where 378 sat under the cap and the reader got 11pt.
    private let measuredSurvivingSlack: CGFloat = 11

    /// What the column is actually pinned to: the stored width clamped to the
    /// range, exactly as `MailRootView.listColumnWidth` computes it.
    private func pinnedWidth(stored: CGFloat, inWindowOfWidth window: CGFloat) -> CGFloat {
        let bounds = ListColumnWidth.pinnedBounds(splitWidth: window)
        return min(max(stored, bounds.minimum), bounds.maximum)
    }

    // The invariant the fix buys, across every regular width and every stored
    // width a user could have dragged to: the pinned column and the reader's
    // floor never add up to the whole window.
    func testThePinnedColumnNeverLeavesTheReaderExactlyItsFloor() {
        for window in stride(from: CGFloat(600), through: 1400, by: 1) {
            for stored in [CGFloat(220), 300, 360, storedWidthBehindTheSweep, 420, 640] {
                let width = pinnedWidth(stored: stored, inWindowOfWidth: window)
                XCTAssertGreaterThanOrEqual(
                    window - width - ListColumnWidth.readerFloor,
                    ListColumnWidth.reservedSlack,
                    "a \(window)pt window with \(stored)pt stored pins an exact fit"
                )
            }
        }
    }

    // The two widths the tester reproduced it at, held against the slack that
    // was measured surviving rather than against the constant alone.
    func testTheReproducedWidthsLeaveTheReaderMoreThanTheMeasuredSlack() {
        for window in brokenSweepWidths {
            let width = pinnedWidth(stored: storedWidthBehindTheSweep,
                                    inWindowOfWidth: window)
            XCTAssertGreaterThanOrEqual(
                window - width - ListColumnWidth.readerFloor,
                measuredSurvivingSlack,
                "\(window)pt still resolves as tightly as the widths that broke"
            )
            XCTAssertLessThan(
                width, window - ListColumnWidth.readerFloor,
                "\(window)pt still pins the column to the old exact-fit ceiling"
            )
        }
    }

    // A window too narrow to seat `minimum` alongside the reader's floor and the
    // slack takes the width from the list — the same call #984 made. A floor
    // left above the ceiling would pin the column wider than the window can
    // seat, which over-subscribes the split rather than merely filling it.
    func testTheFloorFollowsTheCeilingDownInACrampedWindow() {
        for window in stride(from: CGFloat(600), through: 1400, by: 1) {
            let bounds = ListColumnWidth.pinnedBounds(splitWidth: window)
            XCTAssertLessThanOrEqual(bounds.minimum, bounds.maximum,
                                     "empty range in a \(window)pt window")
            XCTAssertGreaterThanOrEqual(bounds.minimum, ListColumnWidth.squeezedMinimum,
                                        "squeezed past the readable floor at \(window)pt")
        }
        let cramped = ListColumnWidth.pinnedBounds(splitWidth: 620)
        XCTAssertLessThan(cramped.minimum, ListColumnWidth.minimum)
    }

    // The squeeze is for cramped windows only: a window with room for all of it
    // still seats the full minimum, and a user's dragged width is still honoured
    // wherever it fits.
    func testARoomyWindowKeepsTheFullMinimumAndTheStoredWidth() {
        let bounds = ListColumnWidth.pinnedBounds(splitWidth: 834)
        XCTAssertEqual(bounds.minimum, ListColumnWidth.minimum)
        XCTAssertEqual(
            pinnedWidth(stored: storedWidthBehindTheSweep, inWindowOfWidth: 834),
            storedWidthBehindTheSweep
        )
    }
}
