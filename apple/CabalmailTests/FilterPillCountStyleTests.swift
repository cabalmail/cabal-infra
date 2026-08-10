import XCTest
@testable import Cabalmail

// Regression coverage for issue #993: on visionOS the filter pills rendered as
// a bare "All / Unread / Flagged" with no numbers. The counts were in the view
// tree the whole time (AX read back `All, 5` / `Unread, 3` / `Flagged, 0`) but
// drawn `.secondary`, which over passthrough glass composites to no visible
// contrast — only the selected pill's number showed at all, faintly, and only
// because of the accent tint behind it. Reproduced in the visionOS 26.5
// simulator, so the fix is keyed to the platform's compositing, not to 27.
final class FilterPillCountStyleTests: XCTestCase {

    // The pill's label sets no foreground style of its own, so it draws at the
    // environment's full-strength foreground. That is the emphasis the tester
    // could read on glass, in the same bar, in the same captures.
    private let legibleOnGlass = FilterPillCountStyle.Emphasis.primary

    func testTheCountIsDrawnAsStronglyAsItsLabelOverGlass() {
        XCTAssertEqual(
            FilterPillCountStyle.countEmphasis(overGlass: true),
            legibleOnGlass,
            "a fill weaker than the label's is what vanished into the room"
        )
    }

    func testTheCountStaysSubordinateWhereTheBarHasAnOpaqueBacking() {
        XCTAssertEqual(FilterPillCountStyle.countEmphasis(overGlass: false), .secondary)
    }

    // The bug is visionOS-only: iPhone renders the same pills legibly today,
    // and this test runs on the Mac, so the platform default has to resolve to
    // the unchanged treatment here.
    func testThePlatformDefaultLeavesTheOpaquePlatformsAlone() {
        XCTAssertFalse(FilterPillCountStyle.overPassthroughGlass)
        XCTAssertEqual(FilterPillCountStyle.countEmphasis(), .secondary)
    }
}
