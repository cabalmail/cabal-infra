import XCTest
@testable import Cabalmail

// The reader's header sets its date, authentication chips, and custom flags
// in a trailing column once the pane is wide enough, so that a short, wide
// pane (an iPhone in landscape) spends fewer rows above the message body. The
// rule keys on the pane's width alone; these pin it to the panes it was tuned
// against.
final class ReaderHeaderColumnPolicyTests: XCTestCase {
    private let threshold = ReaderHeaderColumnPolicy.baseMinPaneWidth

    private func usesTrailingColumn(_ paneWidth: CGFloat) -> Bool {
        ReaderHeaderColumnPolicy.usesTrailingColumn(
            paneWidth: paneWidth,
            minPaneWidth: threshold
        )
    }

    func testAnIPhoneInLandscapeGetsTheTrailingColumn() {
        // iPhone 16 Pro, 874pt long edge less the two 62pt safe-area insets.
        XCTAssertTrue(usesTrailingColumn(750))
        // The narrowest supported landscape: iPhone SE, no insets.
        XCTAssertTrue(usesTrailingColumn(667))
    }

    func testAnIPhoneInPortraitStaysStacked() {
        XCTAssertFalse(usesTrailingColumn(393))
        XCTAssertFalse(usesTrailingColumn(440))
    }

    func testANarrowReadingPaneInAThreeColumnLayoutStaysStacked() {
        // An 11-inch iPad in landscape with the sidebar and list both tiled.
        XCTAssertFalse(usesTrailingColumn(500))
    }

    func testTheThresholdItselfGetsTheTrailingColumn() {
        XCTAssertTrue(usesTrailingColumn(threshold))
        XCTAssertFalse(usesTrailingColumn(threshold - 1))
    }

    func testAnUnmeasuredPaneStaysStacked() {
        XCTAssertFalse(usesTrailingColumn(0))
        XCTAssertFalse(
            ReaderHeaderColumnPolicy.usesTrailingColumn(paneWidth: 0, minPaneWidth: 0),
            "a zero-width pane must not pick the trailing column just because "
                + "the scaled threshold hasn't resolved either"
        )
    }

    func testLargerTypeNeedsAWiderPane() {
        // The view scales the threshold with Dynamic Type; at an
        // accessibility size the landscape iPhone falls back to stacking.
        XCTAssertFalse(
            ReaderHeaderColumnPolicy.usesTrailingColumn(
                paneWidth: 750,
                minPaneWidth: threshold * 1.5
            )
        )
    }

    func testTheTrailingColumnLeavesTheSenderLinesMostOfThePane() {
        let cap = ReaderHeaderColumnPolicy.trailingColumnMaxWidth(paneWidth: threshold)
        XCTAssertEqual(cap, threshold * ReaderHeaderColumnPolicy.trailingColumnMaxFraction)
        XCTAssertLessThan(cap, threshold / 2)
        XCTAssertEqual(ReaderHeaderColumnPolicy.trailingColumnMaxWidth(paneWidth: -10), 0)
    }
}
