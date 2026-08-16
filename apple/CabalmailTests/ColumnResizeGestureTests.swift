import XCTest
@testable import Cabalmail

// Regression coverage for issue #1075: the message-list column's resize handle
// was a 22pt hit-testable strip pinned inside the trailing edge, so it claimed
// every touch that landed on it — including taps on the trailing 22pt of every
// message row, which then did nothing at all (a failed SwiftUI gesture is not
// forwarded to the sibling underneath). The tester's tap map on an iPad Pro 11"
// in portrait: x >= 338 dead on rows 1, 6 and 8; x <= 335 opened the message.
//
// The band is unchanged; what it does with a touch is not. Landing in it no
// longer claims it — only a horizontal-dominant drag does.
final class ColumnResizeGestureTests: XCTestCase {

    // The geometry the tester measured: a 360pt list column, the overlay at
    // {{338, 86}, {22, 1104}}, rows 58pt tall.
    private let columnWidth: CGFloat = 360
    private let bandHeight: CGFloat = 1104

    /// The band view's own bounds, which is the space touches are tested in.
    private var band: CGRect {
        CGRect(x: 0, y: 0, width: ColumnResizeGesture.grabWidth, height: bandHeight)
    }

    /// A touch at `x` in the column, expressed in the band view's space. The
    /// band hugs the trailing edge, so its origin is `columnWidth - grabWidth`
    /// — 338 with the tester's numbers.
    private func pointInBand(columnX: CGFloat, rowY: CGFloat = 195) -> CGPoint {
        CGPoint(x: columnX - (columnWidth - ColumnResizeGesture.grabWidth), y: rowY - 86)
    }

    // MARK: - Which touches the handle is even offered

    func testTheBandIsExactlyTheTrailing22ptOfTheColumn() {
        // Sweep the whole column, not the endpoints: the defect was a boundary
        // in the wrong place, and only a sweep says where it actually is.
        for columnX in stride(from: CGFloat(0), through: columnWidth, by: 0.5) {
            let accepted = ColumnResizeGesture.acceptsTouch(
                at: pointInBand(columnX: columnX),
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
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: columnX), band: band),
                "x=\(columnX) opened the message before the handle existed and must still"
            )
        }
        for columnX in [CGFloat(338), 340, 345] {
            XCTAssertTrue(
                ColumnResizeGesture.acceptsTouch(at: pointInBand(columnX: columnX), band: band),
                "x=\(columnX) is in the grab band"
            )
        }
    }

    func testATouchOutsideTheBandsHeightIsNotTheHandles() {
        // Above the column's content (the navigation bar) and below its last
        // row: the band is tall, not infinite.
        XCTAssertFalse(ColumnResizeGesture.acceptsTouch(at: CGPoint(x: 10, y: -1), band: band))
        XCTAssertFalse(
            ColumnResizeGesture.acceptsTouch(at: CGPoint(x: 10, y: bandHeight + 1), band: band)
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
