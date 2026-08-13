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

    // MARK: - Cmd+Delete ownership (#1047)

    // The chord used to ride the reader's dispose toolbar button. AppKit
    // collapses the trailing items of a crowded toolbar into its own overflow
    // popup — below ~1300pt of window width that is exactly the dispose button
    // — and the key equivalent went with it, so Cmd+Delete became a silent
    // no-op. It now rides a hidden button, and these are the rules deciding
    // which surface installs it.

    func testTheReaderOwnsTheChordForTheMessageItHasOpen() {
        let availability = MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true)
        XCTAssertEqual(availability.disposeChordHost, .reader)
    }

    func testTheListOwnsTheChordForAMultiSelection() {
        // 2+ rows: the reading pane shows the count placeholder, not a message.
        let availability = MessageMenuAvailability(selectedCount: 4, hasOpenMessage: false)
        XCTAssertEqual(availability.disposeChordHost, .list)
    }

    func testNothingToDisposeInstallsTheChordNowhere() {
        XCTAssertEqual(MessageMenuAvailability.none.disposeChordHost, .none)
    }

    // The invariant the comments have been carrying since the always-on list
    // button silently did nothing: never two hosts at once, in any state.
    func testExactlyOneSurfaceEverOwnsTheChord() {
        for selectedCount in 0...5 {
            for hasOpenMessage in [true, false] {
                let availability = MessageMenuAvailability(
                    selectedCount: selectedCount,
                    hasOpenMessage: hasOpenMessage
                )
                let host = availability.disposeChordHost
                XCTAssertEqual(
                    host == .list, selectedCount > 1,
                    "list host disagrees with the multi-selection rule at \(selectedCount)"
                )
                XCTAssertEqual(
                    host == .reader, selectedCount <= 1 && hasOpenMessage,
                    "reader host disagrees with the open-message rule at \(selectedCount)"
                )
            }
        }
    }

    // A multi-selection on compact iPhone keeps the list as host even though a
    // message can also be open behind the selection.
    func testAMultiSelectionOutranksAnOpenMessage() {
        let availability = MessageMenuAvailability(selectedCount: 3, hasOpenMessage: true)
        XCTAssertEqual(availability.disposeChordHost, .list)
    }
}
