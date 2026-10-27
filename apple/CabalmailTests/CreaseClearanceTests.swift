import CoreGraphics
import XCTest
@testable import CabalmailUI

/// The 44 pt keep-out around a book crease, against the Duo simulator's
/// geometry: the division band runs from 455.5 to 495.5 in the 951 pt inner
/// display, so the crease line is at 475.5 and the keep-out runs from 431.5
/// to 519.5. In book pose the list ends at the band's leading edge.
final class CreaseClearanceTests: XCTestCase {
    private let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private var book: FoldState { .vertical(crease: band) }
    private let laptop = FoldState.horizontal(crease: CGRect(x: 0, y: 455.5, width: 669, height: 40))

    func testTheKeepOutIsMeasuredFromTheCreaseLine() {
        XCTAssertEqual(CreaseClearance.keepOut(book), 431.5...519.5)
        XCTAssertNil(CreaseClearance.keepOut(.none))
        XCTAssertNil(CreaseClearance.keepOut(laptop))
    }

    /// The list pinned to the band's leading edge keeps its controls 24 pt
    /// short of its own edge.
    func testTheListOnTheLeadingPageStopsShortOfTheKeepOut() {
        XCTAssertEqual(CreaseClearance.trailingClearance(fold: book, columnEndingAt: 455.5), 24)
        XCTAssertEqual(CreaseClearance.trailingClearance(fold: book, columnEndingAt: 431.5), 0, "ends where it starts")
        XCTAssertEqual(CreaseClearance.trailingClearance(fold: book, columnEndingAt: 320), 0, "inspector open")
        XCTAssertEqual(CreaseClearance.trailingClearance(fold: book, columnEndingAt: 480), 0, "not on the leading page")
    }

    /// The reader beside it starts its content past the keep-out.
    func testTheReaderOnTheTrailingPageStartsPastTheKeepOut() {
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 455.5), 64)
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 456.5), 63, "past the separator")
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 454.5), 65, "within the tolerance")
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 454.4), 0, "starts before the band")
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 320), 0, "inspector open")
        XCTAssertEqual(CreaseClearance.leadingInset(fold: book, columnStartingAt: 519.5), 0, "already clear")
    }

    /// Flat, closed, laptop pose and every other device: nothing moves.
    func testWithNoVerticalFoldNothingIsInset() {
        for fold in [FoldState.none, laptop] {
            XCTAssertEqual(CreaseClearance.trailingClearance(fold: fold, columnEndingAt: 455.5), 0)
            XCTAssertEqual(CreaseClearance.leadingInset(fold: fold, columnStartingAt: 455.5), 0)
        }
    }

    /// Nothing assumes the Duo's 475.5.
    func testAnyCreaseKeepsTheSameDistances() {
        let other = FoldState.vertical(crease: CGRect(x: 200, y: 0, width: 40, height: 600))
        XCTAssertEqual(CreaseClearance.keepOut(other), 176...264)
        XCTAssertEqual(CreaseClearance.trailingClearance(fold: other, columnEndingAt: 200), 24)
        XCTAssertEqual(CreaseClearance.leadingInset(fold: other, columnStartingAt: 200), 64)
    }
}
