import XCTest
@testable import CabalmailUI

/// The top row of a virtualized message list from its scroll offset
/// (`ListPlaceGeometry`): rows are one height, so the content scrolled past
/// the top inset over that height is the index.
final class ListPlaceGeometryTests: XCTestCase {
    private func topRow(_ offset: CGFloat, inset: CGFloat = 0, height: CGFloat = 58) -> Int {
        ListPlaceGeometry.topRow(contentOffset: offset, topInset: inset, rowHeight: height)
    }

    func testTheTopOfTheListIsRowZero() {
        XCTAssertEqual(topRow(0), 0)
    }

    func testAnExactRowMultipleIsThatRow() {
        XCTAssertEqual(topRow(58 * 30), 30)
        XCTAssertEqual(topRow(58 * 700), 700)
    }

    func testAPartlyScrolledRowIsStillTheTopRow() {
        XCTAssertEqual(topRow(58 * 30 + 40), 30)
        XCTAssertEqual(topRow(57), 0)
    }

    /// The pill bar and the navigation bar inset the content: at rest the
    /// offset is minus the inset, and that is the top.
    func testTheTopInsetIsNotScrolledContent() {
        XCTAssertEqual(topRow(-96, inset: 96), 0)
        XCTAssertEqual(topRow(58 * 5 - 96, inset: 96), 5)
    }

    func testOverscrollAtTheTopIsRowZero() {
        XCTAssertEqual(topRow(-140, inset: 96), 0)
        XCTAssertEqual(topRow(-30), 0)
    }

    /// A landing's own scroll stops on a row boundary, which a scaled row
    /// height rounded to pixels can read a fraction of a point short of.
    func testASubPixelShortfallCountsAsThatRow() {
        XCTAssertEqual(topRow(5 * 63.67 - 96 - 0.33, inset: 96, height: 63.67), 5)
        XCTAssertEqual(topRow(58 * 30 - 0.4), 30)
        XCTAssertEqual(topRow(58 * 30 - 2), 29, "but not a visibly earlier row")
    }

    func testAScaledRowHeight() {
        XCTAssertEqual(topRow(72.5 * 12, height: 72.5), 12)
        XCTAssertEqual(topRow(72.5 * 12 + 70, height: 72.5), 12)
    }

    func testADegenerateHeightOrOffsetIsRowZero() {
        XCTAssertEqual(topRow(500, height: 0), 0)
        XCTAssertEqual(topRow(500, height: .nan), 0)
        XCTAssertEqual(topRow(500, height: .infinity), 0)
        XCTAssertEqual(topRow(.nan), 0)
        XCTAssertEqual(topRow(500, inset: .infinity), 0)
    }
}
