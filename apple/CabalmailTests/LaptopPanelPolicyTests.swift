import XCTest
@testable import CabalmailUI

/// iPhone Duo's laptop pose in the split (`LaptopPanelPolicy`, #1649), at the
/// Duo simulator's numbers: a 669 × 951 pt window turned upright, with the
/// fold a 669 × 40 pt band at y 455.5.
@MainActor
final class LaptopPanelPolicyTests: XCTestCase {
    private let band = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    private let split = CGRect(x: 0, y: 0, width: 669, height: 951)

    func testOnlyALaptopFoldAcrossATallWindowArrangesTheMailSplit() {
        let laptop = FoldState.horizontal(crease: band)
        XCTAssertTrue(LaptopPanelPolicy.isArranged(fold: laptop, windowIsTall: true, showsFeeds: false))

        // Flat, book pose, a wide window, or the feed reader, whose actions
        // are still in its navigation bar.
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: .none, windowIsTall: true, showsFeeds: false))
        let book = FoldState.vertical(crease: CGRect(x: 455.5, y: 0, width: 40, height: 669))
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: book, windowIsTall: false, showsFeeds: false))
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: laptop, windowIsTall: false, showsFeeds: false))
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: laptop, windowIsTall: true, showsFeeds: true))
    }

    func testTheReaderReservesWhatRunsPastTheFoldsTopEdge() {
        // A message's content region, above its 56 pt action bar.
        let content = CGRect(x: 0, y: 0, width: 669, height: 895)
        XCTAssertEqual(LaptopPanelPolicy.reserve(below: content, crease: band), 439.5)

        // No fold, or a region that already ends above it.
        XCTAssertEqual(LaptopPanelPolicy.reserve(below: content, crease: nil), 0)
        let short = CGRect(x: 0, y: 0, width: 669, height: 400)
        XCTAssertEqual(LaptopPanelPolicy.reserve(below: short, crease: band), 0)
    }

    func testThePanelRunsFromTheFoldToTheReadersBar() {
        let frame = LaptopPanelPolicy.panelFrame(split: split, crease: band, readerBottom: 895)

        XCTAssertEqual(frame, CGRect(x: 0, y: 495.5, width: 669, height: 399.5))
    }

    func testWithNoBarOrNoReportThePanelRunsToTheSplitsBottom() {
        let placeholder = LaptopPanelPolicy.panelFrame(split: split, crease: band, readerBottom: 951)
        let unreported = LaptopPanelPolicy.panelFrame(split: split, crease: band, readerBottom: nil)

        XCTAssertEqual(placeholder.maxY, 951)
        XCTAssertEqual(unreported, placeholder)
    }

    /// The crease and the reader report window coordinates; the panel is
    /// laid out in the split's.
    func testThePanelIsPlacedInTheSplitsOwnCoordinates() {
        let lowered = CGRect(x: 0, y: 20, width: 669, height: 931)

        let frame = LaptopPanelPolicy.panelFrame(split: lowered, crease: band, readerBottom: 895)

        XCTAssertEqual(frame.minY, 475.5)
        XCTAssertEqual(frame.height, 399.5)
    }

    /// A keyboard or anything else that shortens the reader past the fold
    /// leaves the panel no room rather than a negative height.
    func testAReaderEndingAboveTheFoldLeavesAnEmptyPanel() {
        let frame = LaptopPanelPolicy.panelFrame(split: split, crease: band, readerBottom: 420)

        XCTAssertEqual(frame.height, 0)
    }

    func testTheSlotKeepsTheReadersLastBottom() {
        let slot = LaptopReaderSlot()
        XCTAssertNil(slot.readerBottom)

        slot.readerEnds(at: 895)
        slot.readerEnds(at: 895)

        XCTAssertEqual(slot.readerBottom, 895)
    }
}
