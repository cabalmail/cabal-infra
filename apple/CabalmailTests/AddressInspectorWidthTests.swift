import XCTest
@testable import Cabalmail

// SwiftUI opens the addresses inspector at its preferred width every time it
// is shown, so a width the user dragged it to was gone as soon as the panel
// closed — measured on macOS 27, dragged to 381pt, closed and reopened at
// 300. On macOS the preferred width is now the one the panel was last left at.
final class AddressInspectorWidthTests: XCTestCase {

    func testAPanelNeverResizedOpensAtIdeal() {
        XCTAssertEqual(AddressInspectorWidth.resolved(stored: 0), AddressInspectorWidth.ideal)
    }

    func testAResizedPanelOpensAtTheWidthItWasLeftAt() {
        XCTAssertEqual(AddressInspectorWidth.resolved(stored: 381), 381)
    }

    func testAStoredWidthOutsideTheAllowedRangeIsClamped() {
        XCTAssertEqual(AddressInspectorWidth.resolved(stored: 40), AddressInspectorWidth.minimum)
        XCTAssertEqual(AddressInspectorWidth.resolved(stored: 4000), AddressInspectorWidth.maximum)
    }

    func testADragIsPersisted() {
        XCTAssertTrue(AddressInspectorWidth.shouldPersist(measured: 381, stored: 0))
        XCTAssertTrue(AddressInspectorWidth.shouldPersist(measured: 352, stored: 381))
    }

    // Opening at the width it was asked for is the panel settling, and the
    // hidden panel's layout pass reports a width too; neither is a resize.
    func testSettlingIsNotADrag() {
        XCTAssertFalse(AddressInspectorWidth.shouldPersist(measured: AddressInspectorWidth.ideal, stored: 0))
        XCTAssertFalse(AddressInspectorWidth.shouldPersist(measured: 380.5, stored: 381))
        XCTAssertFalse(AddressInspectorWidth.shouldPersist(measured: 0, stored: 381))
    }

    // The search field reserves room for the inspector at its widest; the
    // remembered width can't take it past that.
    func testARememberedWidthStaysWithinWhatTheSearchFieldAllowsFor() {
        for stored in stride(from: 0.0, through: 1_000.0, by: 10.0) {
            XCTAssertLessThanOrEqual(AddressInspectorWidth.resolved(stored: stored),
                                     AddressInspectorWidth.maximum)
        }
    }
}
