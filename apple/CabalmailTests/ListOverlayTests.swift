import SwiftUI
import XCTest
@testable import CabalmailUI

/// The list floating over a full-width reader in a split taller than wide
/// (`ListOverlay`, #1686): the iPhone Duo open upright and iPad in portrait.
final class ListOverlayTests: XCTestCase {
    func testAWideSplitAlwaysShowsBothColumns() {
        var overlay = ListOverlay()
        overlay.messageChanged(isOpen: true)
        overlay.splitAsked(for: .detailOnly, overlays: false)

        XCTAssertEqual(overlay.visibility(overlays: false), .doubleColumn)
        XCTAssertFalse(overlay.offersMessagesButton(overlays: false))
    }

    func testWithNothingOpenTheListIsShownFirstAndStays() {
        var overlay = ListOverlay()
        XCTAssertEqual(overlay.visibility(overlays: true), .doubleColumn)

        // UIKit puts the floating column away on its own as the split turns
        // to overlaying; with nothing behind it, the list stays.
        overlay.splitAsked(for: .detailOnly, overlays: true)

        XCTAssertEqual(overlay.visibility(overlays: true), .doubleColumn)
    }

    func testAnOpenedMessageTakesTheWindowAndTheButtonBringsTheListBack() {
        var overlay = ListOverlay()
        overlay.messageChanged(isOpen: true)
        XCTAssertEqual(overlay.visibility(overlays: true), .detailOnly)
        XCTAssertTrue(overlay.offersMessagesButton(overlays: true))

        overlay.show()

        XCTAssertEqual(overlay.visibility(overlays: true), .doubleColumn)
        XCTAssertFalse(overlay.offersMessagesButton(overlays: true))
    }

    func testATapOnTheReaderPutsTheListAwayAndASwipeBringsItBack() {
        var overlay = ListOverlay()
        overlay.messageChanged(isOpen: true)
        overlay.show()

        overlay.splitAsked(for: .detailOnly, overlays: true)
        XCTAssertEqual(overlay.visibility(overlays: true), .detailOnly)

        overlay.splitAsked(for: .doubleColumn, overlays: true)
        XCTAssertEqual(overlay.visibility(overlays: true), .doubleColumn)
    }

    func testClosingTheMessageBringsTheListBack() {
        var overlay = ListOverlay()
        overlay.messageChanged(isOpen: true)

        overlay.messageChanged(isOpen: false)

        XCTAssertEqual(overlay.visibility(overlays: true), .doubleColumn)
    }
}
