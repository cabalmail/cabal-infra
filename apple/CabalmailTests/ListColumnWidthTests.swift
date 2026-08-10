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
            ListColumnWidth.maximum(
                splitWidth: observedWindowWidth,
                sidebarWidth: SidebarColumnWidth.ideal
            )
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
        let cap = ListColumnWidth.maximum(
            splitWidth: wideWindow,
            sidebarWidth: SidebarColumnWidth.ideal
        )
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
        let cap = ListColumnWidth.maximum(
            splitWidth: observedWindowWidth,
            sidebarWidth: SidebarColumnWidth.ideal
        )
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
        let cap = ListColumnWidth.maximum(
            splitWidth: smallestSupportedWindow,
            sidebarWidth: SidebarColumnWidth.ideal
        )
        XCTAssertLessThanOrEqual(cap, ListColumnWidth.ideal)
        XCTAssertGreaterThanOrEqual(cap, ListColumnWidth.minimum)
        // 60pt was the measured failure; the cap has to do far better than that
        // even in the window that can least afford all three columns.
        XCTAssertGreaterThan(
            readerWidth(inWindowOfWidth: smallestSupportedWindow, listWidth: cap),
            ListColumnWidth.readerFloor / 2
        )
    }

    // A window too narrow for sidebar + list + reader can't satisfy everyone;
    // the list must still be given its minimum rather than a negative width.
    func testAnImpossiblyNarrowWindowStillReportsTheMinimum() {
        XCTAssertEqual(
            ListColumnWidth.maximum(splitWidth: 400, sidebarWidth: SidebarColumnWidth.ideal),
            ListColumnWidth.minimum
        )
    }

    // `.onGeometryChange` hasn't fired when the column is first built. A cap
    // derived from that zero width would pin the column to its floor for the
    // first layout and flick it wider a frame later.
    func testThePreLayoutMeasurementOpensAtTheIdealWidth() {
        XCTAssertEqual(
            ListColumnWidth.maximum(splitWidth: 0, sidebarWidth: SidebarColumnWidth.ideal),
            ListColumnWidth.ideal
        )
    }

    func testTheBoundsAreOrdered() {
        XCTAssertLessThan(ListColumnWidth.minimum, ListColumnWidth.ideal)
    }
}
