import XCTest
@testable import CabalmailKit

final class DisposeIntentTests: XCTestCase {

    // MARK: standard (preference-driven surfaces: swipe, reader button, Cmd+Delete)

    func testStandardDisposeInAnOrdinaryFolderFollowsThePreference() {
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "INBOX"), .move(.archive))
        XCTAssertEqual(DisposeIntent.standard(preference: .trash, in: "INBOX"), .move(.trash))
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "Projects/Q3"), .move(.archive))
    }

    func testStandardDisposeInsideArchiveRestoresRatherThanArchivingOntoItself() {
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "Archive"), .restore)
    }

    /// The other half of the preference stays meaningful inside Archive:
    /// deleting an archived message is a real move to Trash.
    func testTrashPreferenceInsideArchiveStillTrashes() {
        XCTAssertEqual(DisposeIntent.standard(preference: .trash, in: "Archive"), .move(.trash))
    }

    /// Trash is decided before the preference is consulted — the swipe and
    /// the reader button are Delete Forever there either way.
    func testStandardDisposeInsideTrashPurgesWhicheverWayThePreferencePoints() {
        XCTAssertEqual(DisposeIntent.standard(preference: .trash, in: "Trash"), .purge)
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "Trash"), .purge)
    }

    /// A folder that merely contains the word is not the special-use one.
    func testFolderNamedLikeArchiveIsNotArchive() {
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "Archive/2025"), .move(.archive))
        XCTAssertEqual(DisposeIntent.standard(preference: .archive, in: "Work Archive"), .move(.archive))
    }

    // MARK: archiving (explicit Archive items: context menus, bulk bar, overflow alternate)

    func testExplicitArchiveInsideArchiveRestores() {
        XCTAssertEqual(DisposeIntent.archiving(in: "Archive"), .restore)
    }

    func testExplicitArchiveElsewhereArchives() {
        XCTAssertEqual(DisposeIntent.archiving(in: "INBOX"), .move(.archive))
        XCTAssertEqual(DisposeIntent.archiving(in: "Projects/Q3"), .move(.archive))
    }

    /// Inside Trash the Archive item is the rescue path out of the deleted
    /// pile, not a same-folder move — it must not become Restore or purge.
    func testExplicitArchiveInsideTrashStaysARealArchive() {
        XCTAssertEqual(DisposeIntent.archiving(in: "Trash"), .move(.archive))
    }

    // MARK: destination + destructiveness

    func testDestinationFolderMatchesTheIntent() {
        XCTAssertEqual(DisposeIntent.move(.archive).destinationFolder, "Archive")
        XCTAssertEqual(DisposeIntent.move(.trash).destinationFolder, "Trash")
        XCTAssertEqual(DisposeIntent.restore.destinationFolder, "INBOX")
        XCTAssertNil(DisposeIntent.purge.destinationFolder)
    }

    /// A restore never moves a message onto the folder it is already in —
    /// that same-folder move is the whole defect this type exists to stop.
    func testResolvedIntentNeverTargetsTheFolderItActsIn() {
        for folder in ["INBOX", "Archive", "Trash", "Projects/Q3"] {
            for preference in DisposeAction.allCases {
                let standard = DisposeIntent.standard(preference: preference, in: folder)
                XCTAssertNotEqual(standard.destinationFolder, folder, "standard/\(preference) in \(folder)")
                let archiving = DisposeIntent.archiving(in: folder)
                XCTAssertNotEqual(archiving.destinationFolder, folder, "archiving in \(folder)")
            }
        }
    }

    func testOnlyTrashDestinationsReadAsDestructive() {
        XCTAssertFalse(DisposeIntent.move(.archive).isDestructive)
        XCTAssertFalse(DisposeIntent.restore.isDestructive)
        XCTAssertTrue(DisposeIntent.move(.trash).isDestructive)
        XCTAssertTrue(DisposeIntent.purge.isDestructive)
    }
}
