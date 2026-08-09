import XCTest
@testable import Cabalmail

// Regression coverage for issue #985: the Message menu left Reply, Reply All,
// Forward, Mark as Read/Unread, Flag/Unflag and Move to Folder… enabled with
// no message selected, and choosing one did nothing — the handlers act on
// `shortcutTargetUIDs` (the selection, else the open message) or on the open
// message in `MessageDetailView`, all of which are empty then. Availability
// has to answer those same two target rules.
final class MessageMenuAvailabilityTests: XCTestCase {

    func testNothingSelectedDimsEveryCommand() {
        let availability = MessageMenuAvailability.none
        XCTAssertFalse(availability.canReply)
        XCTAssertFalse(availability.canActOnSelection)
    }

    // A plain click on a wide layout lands in the selection set and opens the
    // reading pane, so the whole menu is live.
    func testOneSelectedMessageEnablesEverything() {
        let availability = MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true)
        XCTAssertTrue(availability.canReply)
        XCTAssertTrue(availability.canActOnSelection)
    }

    // Multi-selection closes the reading pane for a count placeholder, and
    // the reply family is handled by the reader — so those stay dimmed while
    // the selection-scoped actions work on all of them.
    func testAMultiSelectionKeepsTheReplyFamilyDimmed() {
        let availability = MessageMenuAvailability(selectedCount: 3, hasOpenMessage: false)
        XCTAssertFalse(availability.canReply)
        XCTAssertTrue(availability.canActOnSelection)
    }

    // Compact iPhone opens a message without putting it in the list's
    // selection set; `shortcutTargetUIDs` falls back to the open message, so
    // the selection-scoped commands act on it and stay enabled.
    func testAnOpenMessageWithNoListSelectionStillHasTargets() {
        let availability = MessageMenuAvailability(selectedCount: 0, hasOpenMessage: true)
        XCTAssertTrue(availability.canReply)
        XCTAssertTrue(availability.canActOnSelection)
    }
}
