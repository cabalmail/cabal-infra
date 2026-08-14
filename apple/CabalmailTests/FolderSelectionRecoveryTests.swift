import XCTest
import CabalmailKit
@testable import Cabalmail

/// Deleting the folder the sidebar has selected used to leave the selection
/// pointing at it, so the message-list column kept requesting a path the
/// server had just removed and refreshing it rendered a bare "Internal server
/// error." (#1062).
final class FolderSelectionRecoveryTests: XCTestCase {
    func testASelectionThatSurvivesIsLeftAlone() {
        let inbox = Self.folder("INBOX")
        let keep = Self.folder("Projects")
        let next = FolderSelectionRecovery.selection(
            current: keep,
            remaining: [inbox, keep]
        )
        XCTAssertEqual(next?.path, "Projects")
    }

    func testDeletingTheSelectedFolderFallsBackToInbox() {
        let inbox = Self.folder("INBOX")
        let next = FolderSelectionRecovery.selection(
            current: Self.folder("t27-0814b"),
            remaining: [inbox, Self.folder("Projects")]
        )
        XCTAssertEqual(next?.path, "INBOX")
    }

    func testAChildOfADeletedParentKeepsItsSelection() {
        // IMAP keeps a deleted folder's name as a `\Noselect` container when
        // it has children, so the child is still selectable — the rule reads
        // the surviving list rather than the deleted path's prefix.
        let child = Self.folder("Projects/Alpha")
        let next = FolderSelectionRecovery.selection(
            current: child,
            remaining: [Self.folder("INBOX"), child]
        )
        XCTAssertEqual(next?.path, "Projects/Alpha")
    }

    func testAnEmptySelectionStaysEmpty() {
        let next = FolderSelectionRecovery.selection(
            current: nil,
            remaining: [Self.folder("INBOX")]
        )
        XCTAssertNil(next)
    }

    func testWithoutInboxTheFirstSurvivingFolderIsTaken() {
        // Not reachable on a real account, but the fallback must not hand
        // back nil and strand the column with no folder at all.
        let next = FolderSelectionRecovery.selection(
            current: Self.folder("gone"),
            remaining: [Self.folder("Archive"), Self.folder("Sent")]
        )
        XCTAssertEqual(next?.path, "Archive")
    }

    func testNothingLeftClearsTheSelection() {
        let next = FolderSelectionRecovery.selection(
            current: Self.folder("gone"),
            remaining: []
        )
        XCTAssertNil(next)
    }

    private static func folder(_ path: String) -> Folder {
        Folder(path: path)
    }
}
