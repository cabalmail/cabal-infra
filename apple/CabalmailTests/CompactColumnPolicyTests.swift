import XCTest
import SwiftUI
@testable import Cabalmail

// Regression coverage for issue #844: sending a draft from inside the reader
// on iPhone left the user on the "No message selected / Pick a message from
// the list to read it." placeholder, full screen, with no list beside it to
// pick from. The send prunes the row backing the pushed reader, selection
// goes nil, and the collapsed navigation stayed parked on `.detail`. The same
// dead end applies to an archive or move made from the reader when there's no
// next message to advance to. Losing the selection while the reader is up now
// pops back to the message list.
final class CompactColumnPolicyTests: XCTestCase {

    func testSelectingAMessagePushesTheReader() {
        XCTAssertEqual(
            CompactColumnPolicy.column(hasSelectedMessage: true, current: .content),
            .detail
        )
    }

    func testLosingTheReadMessagePopsBackToTheList() {
        XCTAssertEqual(
            CompactColumnPolicy.column(hasSelectedMessage: false, current: .detail),
            .content,
            "the message being read is gone, and compact has no list beside the reader to fall back on"
        )
    }

    func testSelectionClearedWhileOnTheListStaysOnTheList() {
        XCTAssertEqual(
            CompactColumnPolicy.column(hasSelectedMessage: false, current: .content),
            .content
        )
    }

    func testSelectionClearedWhileOnTheSidebarStaysOnTheSidebar() {
        // A folder switch clears the selection and parks the column itself;
        // this must not yank the user off the folder list.
        XCTAssertEqual(
            CompactColumnPolicy.column(hasSelectedMessage: false, current: .sidebar),
            .sidebar
        )
    }
}
