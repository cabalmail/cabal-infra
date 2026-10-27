import XCTest
@testable import CabalmailUI

// Regression coverage for issue #1075: the message-list column's resize handle
// was a 22pt hit-testable strip pinned inside the trailing edge, so it claimed
// every touch that landed on it — including taps on the trailing 22pt of every
// message row, which then did nothing at all (a failed SwiftUI gesture is not
// forwarded to the sibling underneath). The tester's tap map on an iPad Pro 11"
// in portrait: x >= 338 dead on rows 1, 6 and 8; x <= 335 opened the message.
//
// Landing in the band no longer claims a touch — only a horizontal-dominant
// drag does. And since the iPhone Duo spec's "a drag starts only on the
// visible grabber" the band is no longer the column's full height either: it
// is the 22pt-wide, 44pt-tall target centred on the grip, so a row above or
// below it keeps its whole trailing edge, swipe included.
final class ColumnResizeGestureTests: XCTestCase {

    // The geometry the tester measured: a 360pt list column whose content ran
    // from y 86 for 1104pt, rows 58pt tall. The grip is centred on that edge,
    // so the target runs from y 616 to 660.
    private let columnWidth: CGFloat = 360
    private let columnTop: CGFloat = 86
    private let columnHeight: CGFloat = 1104
    private var bandTop: CGFloat { columnTop + (columnHeight - ColumnResizeGesture.grabHeight) / 2 }
    /// A row's y that runs through the grip.
    private var gripRowY: CGFloat { bandTop + ColumnResizeGesture.grabHeight / 2 }

    /// The band view's own bounds, which is the space touches are tested in.
    private var band: CGRect {
        CGRect(x: 0, y: 0, width: ColumnResizeGesture.grabWidth, height: ColumnResizeGesture.grabHeight)
    }

    /// A touch at `x` in the column, expressed in the band view's space. The
    /// band hugs the trailing edge, so its origin is `columnWidth - grabWidth`
    /// — 338 with the tester's numbers.
    private func pointInBand(columnX: CGFloat, rowY: CGFloat) -> CGPoint {
        CGPoint(x: columnX - (columnWidth - ColumnResizeGesture.grabWidth), y: rowY - bandTop)
    }

    // MARK: - Which touches the handle is even offered

    func testTheBandIsExactlyTheTrailing22ptOfTheColumn() {
        // Sweep the whole column, not the endpoints: the defect was a boundary
        // in the wrong place, and only a sweep says where it actually is.
        for columnX in stride(from: CGFloat(0), through: columnWidth, by: 0.5) {
            let accepted = ColumnResizeGesture.acceptsTouch(
                at: pointInBand(columnX: columnX, rowY: gripRowY),
                band: band
            )
            // Half-open at the trailing edge, as `CGRect.contains` is: x=360
            // is the boundary itself and no touch lands on it.
            XCTAssertEqual(
                accepted,
                columnX >= columnWidth - ColumnResizeGesture.grabWidth && columnX < columnWidth,
                "x=\(columnX) in a \(columnWidth)pt column"
            )
        }
    }

    func testATouchOnTheRowBodyIsNeverTheHandles() {
        // The three coordinates the tester found dead, and the three that worked.
        for columnX in [CGFloat(180), 328, 330, 335] {
            XCTAssertFalse(
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: columnX, rowY: gripRowY), band: band),
                "x=\(columnX) opened the message before the handle existed and must still"
            )
        }
        for columnX in [CGFloat(338), 340, 345] {
            XCTAssertTrue(
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: columnX, rowY: gripRowY), band: band),
                "x=\(columnX) on the grip's row is in the grab band"
            )
            // The tester's rows 1, 6 and 8 were nowhere near the grip: their
            // trailing edge is the row's again.
            XCTAssertFalse(
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: columnX, rowY: 195), band: band),
                "x=\(columnX) on a row away from the grip belongs to the row"
            )
        }
    }

    /// Only the grip's own height is the handle's: a drag starts on the
    /// visible grabber and nowhere else along the column's edge.
    func testOnlyTheGripsHeightOfTheEdgeIsTheHandles() {
        for rowY in stride(from: columnTop, through: columnTop + columnHeight, by: 0.5) {
            XCTAssertEqual(
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: 349, rowY: rowY), band: band),
                rowY >= bandTop && rowY < bandTop + ColumnResizeGesture.grabHeight,
                "y=\(rowY) on the column's trailing edge"
            )
        }
    }

    /// The smallest target Apple recommends, and more than the grip it is
    /// centred on.
    func testTheGrabTargetIsAFingersSize() {
        XCTAssertGreaterThanOrEqual(ColumnResizeGesture.grabHeight, 44)
        XCTAssertGreaterThan(ColumnResizeGesture.grabHeight, 36)
    }

    /// The drag is always offered a touch on the grip; the reset's double tap
    /// and long press only while there is a width to clear, so with none a
    /// tap on the grip reaches its row without waiting for a second tap.
    func testTheResetIsOfferedTheGripOnlyWithAWidthToClear() {
        let onGrip = pointInBand(columnX: 349, rowY: gripRowY)
        let offGrip = pointInBand(columnX: 349, rowY: 195)
        for canReset in [false, true] {
            XCTAssertTrue(ColumnResizeGesture.offersTouch(to: .drag, at: onGrip, band: band, canReset: canReset))
            XCTAssertEqual(
                ColumnResizeGesture.offersTouch(to: .reset, at: onGrip, band: band, canReset: canReset),
                canReset
            )
            for recognizer in [ColumnResizeGesture.Recognizer.drag, .reset] {
                XCTAssertFalse(
                    ColumnResizeGesture.offersTouch(to: recognizer, at: offGrip, band: band, canReset: canReset)
                )
            }
        }
    }

    func testATouchOutsideTheBandsHeightIsNotTheHandles() {
        // Just above and just below the grip: the band is the grip's height,
        // not the column's.
        XCTAssertFalse(ColumnResizeGesture.acceptsTouch(at: CGPoint(x: 10, y: -1), band: band))
        XCTAssertFalse(
            ColumnResizeGesture.acceptsTouch(at: CGPoint(x: 10, y: ColumnResizeGesture.grabHeight + 1), band: band)
        )
    }

    // MARK: - What an accepted touch has to be to claim the row's touch

    func testATapInTheBandIsNotAResize() {
        // This is the defect, stated as a rule: a touch that goes nowhere
        // belongs to the row, and the row opens the message.
        XCTAssertFalse(ColumnResizeGesture.beginsResize(translation: .zero))
    }

    func testAVerticalDragInTheBandScrollsTheListInstead() {
        for deltaY in stride(from: CGFloat(-200), through: 200, by: 5) where deltaY != 0 {
            XCTAssertFalse(
                ColumnResizeGesture.beginsResize(translation: CGSize(width: 0, height: deltaY)),
                "a straight vertical drag of \(deltaY) is a scroll"
            )
        }
        // A drag no steeper than 45 degrees still reads as a scroll rather than
        // a resize, so a slightly slanted flick keeps scrolling the list.
        XCTAssertFalse(ColumnResizeGesture.beginsResize(translation: CGSize(width: 30, height: 30)))
        XCTAssertFalse(ColumnResizeGesture.beginsResize(translation: CGSize(width: -20, height: 40)))
    }

    func testAHorizontalDragInTheBandResizes() {
        // Both directions: the column narrows as readily as it widens.
        for deltaX in stride(from: CGFloat(-200), through: 200, by: 5) where abs(deltaX) > 0 {
            XCTAssertTrue(
                ColumnResizeGesture.beginsResize(translation: CGSize(width: deltaX, height: 0)),
                "a horizontal drag of \(deltaX) is a resize"
            )
        }
        XCTAssertTrue(ColumnResizeGesture.beginsResize(translation: CGSize(width: 40, height: 20)))
        XCTAssertTrue(ColumnResizeGesture.beginsResize(translation: CGSize(width: -40, height: -12)))
    }

    // MARK: - The resize itself (unchanged behaviour, now under test)

    func testADragTracksTheFingerOnePointForOne() {
        // Inside the column's range, where the clamp has nothing to say: from
        // 360 with a 300...640 range that is a 60pt drag left and 280 right.
        for deltaX in stride(from: CGFloat(-60), through: 280, by: 1) {
            XCTAssertEqual(
                ColumnResizeGesture.resizedWidth(
                    anchor: 360, translation: deltaX, minWidth: 300, maxWidth: 640
                ),
                360 + deltaX,
                accuracy: 0.001,
                "a drag of \(deltaX) from 360 has to land on \(360 + deltaX), not half of it"
            )
        }
    }

    func testTheWidthNeverLeavesTheColumnsAllowedRange() {
        for deltaX in stride(from: CGFloat(-2000), through: 2000, by: 10) {
            let resized = ColumnResizeGesture.resizedWidth(
                anchor: 360, translation: deltaX, minWidth: 300, maxWidth: 640
            )
            XCTAssertGreaterThanOrEqual(resized, 300)
            XCTAssertLessThanOrEqual(resized, 640)
        }
    }
}
