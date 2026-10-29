import CoreGraphics
import XCTest
@testable import CabalmailUI

/// The fold as layout reads it: which way a region runs, where its crease is
/// in a view's own coordinates, and the pieces of a view it leaves. The
/// numbers are the Studio's Duo simulator readings from the Oct 7 spec: a
/// 951 x 669 pt inner display with a 40 pt fold region around a crease at
/// 475.5 pt, and the same window turned upright in laptop pose.
final class FoldStateTests: XCTestCase {
    private let book = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private let laptop = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    func testATallRegionIsAVerticalFold() {
        XCTAssertEqual(FoldState(region: book), .vertical(crease: book))
    }

    func testAWideRegionIsAHorizontalFold() {
        XCTAssertEqual(FoldState(region: laptop), .horizontal(crease: laptop))
    }

    func testNoRegionAnEmptyOneOrASquareOneIsNoFold() {
        XCTAssertEqual(FoldState(region: nil), .none)
        XCTAssertEqual(FoldState(region: .zero), .none)
        XCTAssertEqual(FoldState(region: CGRect(x: 10, y: 10, width: 0, height: 669)), .none)
        XCTAssertEqual(FoldState(region: CGRect(x: 0, y: 0, width: 40, height: 40)), .none)
        XCTAssertFalse(FoldState.none.isFolded)
        XCTAssertNil(FoldState.none.crease)
    }

    func testTheCreaseIsBroughtIntoAViewsOwnCoordinates() {
        // The reader column of a book-pose split, starting where a 360 pt
        // list ends.
        let reader = CGRect(x: 360, y: 0, width: 591, height: 669)
        XCTAssertEqual(
            FoldState(region: book).crease(inViewAt: reader),
            CGRect(x: 95.5, y: 0, width: 40, height: 669)
        )
        XCTAssertNil(FoldState.none.crease(inViewAt: reader))
    }

    func testAVerticalFoldSplitsAWholeWindowSideBySide() {
        let window = CGRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertEqual(
            FoldPieces(bounds: window, fold: FoldState(region: book), frameInWindow: window),
            .sideBySide(
                leading: CGRect(x: 0, y: 0, width: 455.5, height: 669),
                trailing: CGRect(x: 495.5, y: 0, width: 455.5, height: 669)
            )
        )
    }

    func testAHorizontalFoldStacksAWholeWindow() {
        let window = CGRect(x: 0, y: 0, width: 669, height: 951)
        XCTAssertEqual(
            FoldPieces(bounds: window, fold: FoldState(region: laptop), frameInWindow: window),
            .stacked(
                top: CGRect(x: 0, y: 0, width: 669, height: 455.5),
                bottom: CGRect(x: 0, y: 495.5, width: 669, height: 455.5)
            )
        )
    }

    /// A view inset from the window's corner, as one inside the safe area
    /// is, gets its pieces in its own coordinates.
    func testPiecesAreInTheViewsOwnCoordinates() {
        let frame = CGRect(x: 0, y: 24, width: 867, height: 645)
        let bounds = CGRect(origin: .zero, size: frame.size)
        XCTAssertEqual(
            FoldPieces(bounds: bounds, fold: FoldState(region: book), frameInWindow: frame),
            .sideBySide(
                leading: CGRect(x: 0, y: 0, width: 455.5, height: 645),
                trailing: CGRect(x: 495.5, y: 0, width: 371.5, height: 645)
            )
        )
    }

    func testAViewTheCreaseMissesIsWhole() {
        let list = CGRect(x: 0, y: 0, width: 360, height: 669)
        let bounds = CGRect(origin: .zero, size: list.size)
        XCTAssertEqual(
            FoldPieces(bounds: bounds, fold: FoldState(region: book), frameInWindow: list),
            .whole(bounds)
        )
        XCTAssertEqual(
            FoldPieces(bounds: bounds, fold: .none, frameInWindow: list),
            .whole(bounds)
        )
    }

    /// A crease over one edge of the view leaves it one piece, the part
    /// clear of the crease, never an empty sliver on the far side.
    func testACreaseOverOneEdgeLeavesTheRestWhole() {
        let list = CGRect(x: 0, y: 0, width: 480, height: 669)
        let bounds = CGRect(origin: .zero, size: list.size)
        XCTAssertEqual(
            FoldPieces(bounds: bounds, fold: FoldState(region: book), frameInWindow: list),
            .whole(CGRect(x: 0, y: 0, width: 455.5, height: 669))
        )
    }
}
