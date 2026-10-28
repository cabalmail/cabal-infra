import XCTest
@testable import CabalmailUI

/// Compose's Cancel and Send carry symbols only where the window's bars are
/// a side strip (#2259, #2262), and keep their titles everywhere else.
final class ComposeBarLabelTests: XCTestCase {
    func testCancelHasASymbolOnlyInAStrip() {
        XCTAssertEqual(ComposeBarLabel.cancel(barsAreVertical: true), .symbol)
        XCTAssertEqual(ComposeBarLabel.cancel(barsAreVertical: false), .title)
    }

    func testSendKeepsItsSymbolInAStripWhileSending() {
        XCTAssertEqual(ComposeBarLabel.send(barsAreVertical: true, isSending: false), .symbol)
        XCTAssertEqual(ComposeBarLabel.send(barsAreVertical: true, isSending: true), .symbol)
    }

    func testSendInAHorizontalBarShowsItsTitleThenASpinner() {
        XCTAssertEqual(ComposeBarLabel.send(barsAreVertical: false, isSending: false), .title)
        XCTAssertEqual(ComposeBarLabel.send(barsAreVertical: false, isSending: true), .progress)
    }
}
