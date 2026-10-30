import XCTest
import CoreGraphics
@testable import CabalmailUI

/// Where a window's sheets go, by its shape (`SheetPlacementPolicy`): the
/// compose sheet and Cabalmail's own sheets alike.
final class SheetPlacementPolicyTests: XCTestCase {
    private func trailing(wide: Bool, width regular: Bool, height regularHeight: Bool) -> Bool {
        SheetPlacementPolicy.sitsTrailing(
            windowIsWide: wide, isRegularWidth: regular, isRegularHeight: regularHeight
        )
    }

    /// A wide, regular window: an iPad in landscape, or an open iPhone Duo
    /// held wide, flat or in book pose. The sheet leaves the window's
    /// leading side in view, and its bar is a strip on the hardware edge.
    func testAWideRegularWindowPutsTheSheetOnTheTrailingSide() {
        XCTAssertTrue(trailing(wide: true, width: true, height: true))
    }

    /// A tall window (an iPad or the Duo's inner display upright) keeps the
    /// system's centred sheet.
    func testATallWindowKeepsTheSystemPlacement() {
        XCTAssertFalse(trailing(wide: false, width: true, height: true))
    }

    /// A compact window takes the sheet across its width anyway: an iPhone,
    /// a closed Duo, a large iPhone held wide (regular width, compact
    /// height), or a short, narrow iPad window (compact width, regular
    /// height).
    func testACompactWindowKeepsTheSystemPlacement() {
        XCTAssertFalse(trailing(wide: true, width: true, height: false))
        XCTAssertFalse(trailing(wide: true, width: false, height: true))
        XCTAssertFalse(trailing(wide: true, width: false, height: false))
        XCTAssertFalse(trailing(wide: false, width: false, height: true))
    }

    /// In laptop pose Cabalmail's own sheets keep below the fold; flat, in
    /// book pose and on every display that doesn't fold they take the
    /// system's height.
    func testOnlyLaptopPoseKeepsASheetBelowTheFold() {
        let laptop = FoldState.horizontal(crease: CGRect(x: 0, y: 455, width: 669, height: 40))
        let book = FoldState.vertical(crease: CGRect(x: 455, y: 0, width: 40, height: 669))
        XCTAssertTrue(SheetPlacementPolicy.staysBelowFold(laptop))
        XCTAssertFalse(SheetPlacementPolicy.staysBelowFold(book))
        XCTAssertFalse(SheetPlacementPolicy.staysBelowFold(.none))
    }
}
