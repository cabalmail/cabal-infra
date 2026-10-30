import XCTest
@testable import CabalmailUI

/// iPhone Duo's laptop pose in the split (`LaptopPanelPolicy`, #1649), at the
/// Duo simulator's numbers: a 669 × 951 pt window turned upright, with the
/// fold a 669 × 40 pt band at y 455.5.
@MainActor
final class LaptopPanelPolicyTests: XCTestCase {
    private let band = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    private let split = CGRect(x: 0, y: 0, width: 669, height: 951)

    func testOnlyALaptopFoldAcrossATallWindowArrangesTheSplit() {
        let laptop = FoldState.horizontal(crease: band)
        XCTAssertTrue(LaptopPanelPolicy.isArranged(fold: laptop, windowIsTall: true))

        // Flat, book pose, or a wide window.
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: .none, windowIsTall: true))
        let book = FoldState.vertical(crease: CGRect(x: 455.5, y: 0, width: 40, height: 669))
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: book, windowIsTall: false))
        XCTAssertFalse(LaptopPanelPolicy.isArranged(fold: laptop, windowIsTall: false))
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

/// Addresses in laptop pose (`LaptopAddressesPolicy`, #1649): the panel's
/// address list, and how it trades places with the inspector across a fold.
@MainActor
final class LaptopAddressesPolicyTests: XCTestCase {
    private typealias Policy = LaptopAddressesPolicy
    private let closed = InspectorPresentationPolicy.State(presented: false, requested: false)
    private let open = InspectorPresentationPolicy.State(presented: true, requested: true)

    func testThePanelsAtSwapsTheListForAddressesAndBack() {
        let list = Policy.State(inspector: closed, inPanel: false)

        let addresses = Policy.toggled(list)
        XCTAssertEqual(addresses, Policy.State(inspector: closed, inPanel: true), "never the inspector")
        XCTAssertEqual(Policy.toggled(addresses), list)
    }

    func testAnOpenInspectorMovesIntoThePanelAsTheSplitArranges() {
        let arranged = Policy.split(arranged: true, Policy.State(inspector: open, inPanel: false))

        XCTAssertEqual(arranged, Policy.State(inspector: closed, inPanel: true))
        // A closed one leaves the panel its list.
        let list = Policy.State(inspector: closed, inPanel: false)
        XCTAssertEqual(Policy.split(arranged: true, list), list)
    }

    /// Opened as the `@` opens it, so the framework's write-back of a
    /// present keeps it (`InspectorPresentationPolicy`).
    func testThePanelsAddressesMoveIntoTheInspectorAsTheSplitLeavesLaptopPose() {
        let left = Policy.split(arranged: false, Policy.State(inspector: closed, inPanel: true))

        XCTAssertEqual(left, Policy.State(inspector: open, inPanel: false))
        XCTAssertEqual(InspectorPresentationPolicy.framework(wrote: true, to: left.inspector), open)
        // The list in the panel leaves the inspector closed.
        let list = Policy.State(inspector: closed, inPanel: false)
        XCTAssertEqual(Policy.split(arranged: false, list), list)
    }

    func testAMessageOrAListOpenedEndsTheAddresses() {
        let addresses = Policy.State(inspector: closed, inPanel: true)

        XCTAssertEqual(Policy.ended(addresses), Policy.State(inspector: closed, inPanel: false))
        // The inspector is not the panel's to close.
        let inspector = Policy.State(inspector: open, inPanel: false)
        XCTAssertEqual(Policy.ended(inspector), inspector)
    }

    func testWithAddressesThePanelRunsOverTheReadersBarToTheSplitsBottom() {
        let band = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let split = CGRect(x: 0, y: 0, width: 669, height: 951)
        let bottom = Policy.panelReaderBottom(895, covered: true)

        XCTAssertEqual(LaptopPanelPolicy.panelFrame(split: split, crease: band, readerBottom: bottom).maxY, 951)
        XCTAssertEqual(Policy.panelReaderBottom(895, covered: false), 895)
    }

    func testTheMenusHearNothingOfACoveredReader() {
        let covered = Policy.reported(selectionCount: 3, isOpen: true, covered: true)
        XCTAssertEqual(covered.selectionCount, 0)
        XCTAssertFalse(covered.isOpen)

        let shown = Policy.reported(selectionCount: 3, isOpen: true, covered: false)
        XCTAssertEqual(shown.selectionCount, 3)
        XCTAssertTrue(shown.isOpen)
    }
}
