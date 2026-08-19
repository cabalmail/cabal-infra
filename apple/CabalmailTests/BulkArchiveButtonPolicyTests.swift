import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1164: the bulk action bar's first button
// drew "Archive" over an archivebox glyph but dispatched the account's
// `Dispose action` preference, so under `Dispose action = Trash` it deleted
// every selection the user asked to archive — on iPhone, iPad and macOS
// alike, with no confirmation for a small selection and nothing in the
// caption, glyph or AX label to say so. The caption and the operation now
// come out of one `BulkArchiveButtonPolicy.button(in:)` call, which takes
// the folder and deliberately not the preference.
final class BulkArchiveButtonPolicyTests: XCTestCase {

    func testOrdinaryFolderArchivesWhateverTheDisposePreferenceIs() {
        let button = BulkArchiveButtonPolicy.button(in: "INBOX")

        XCTAssertEqual(button.title, "Archive")
        XCTAssertEqual(button.systemImage, "archivebox")
        XCTAssertEqual(
            button.intent,
            .move(.archive),
            "the button says Archive, so it must file into Archive — the bar carries a separate Move… for anything else"
        )

        // The preference is genuinely in effect on this screen; it is the
        // preference-driven surfaces (trailing swipe, reader dispose button,
        // Cmd+Delete) that follow it, and this button that must not.
        XCTAssertEqual(
            DisposeIntent.standard(preference: .trash, in: "INBOX"),
            .move(.trash),
            "sanity: a Trash preference does point the default dispose surfaces at Trash"
        )
    }

    func testInsideArchiveTheButtonRestores() {
        let button = BulkArchiveButtonPolicy.button(in: FolderTree.archivePath)

        XCTAssertEqual(button.title, "Restore")
        XCTAssertEqual(button.systemImage, "tray.and.arrow.up")
        XCTAssertEqual(button.intent, .restore, "archiving inside Archive is a same-folder move; restore instead")
    }

    func testInsideTrashTheButtonIsStillTheRescueOutOfTheDeletedPile() {
        let button = BulkArchiveButtonPolicy.button(in: FolderTree.trashPath)

        XCTAssertEqual(button.title, "Archive")
        XCTAssertEqual(button.systemImage, "archivebox")
        XCTAssertEqual(button.intent, .move(.archive), "Archive out of Trash is a rescue, not a same-folder no-op")
    }

    func testTheButtonIsNeverAPurge() {
        // The bar draws its own destructive Delete inside Trash; this button
        // must never be the one that deletes forever, which is what lets
        // `bulkArchive` treat `.purge` as unreachable.
        for path in ["INBOX", "Sent", "Drafts", FolderTree.archivePath, FolderTree.trashPath] {
            XCTAssertNotEqual(BulkArchiveButtonPolicy.button(in: path).intent, .purge, "\(path)")
        }
    }
}
