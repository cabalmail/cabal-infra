import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the shared mail reader column shows (`MailReaderChoice`). Every shell
/// reads through the same rule — the Mac window, the iPad split, the visionOS
/// Mail tab — so the rule is pinned here, on the Mac host, for all of them.
final class MailReaderChoiceTests: XCTestCase {

    private let inbox = Folder(path: "INBOX")

    func testTwoOrMoreSelectedShowsTheCountEvenWithAMessageOpen() {
        let open = TestFixtures.makeEnvelope(uid: 7).inFolder("INBOX")
        XCTAssertEqual(
            MailReaderChoice.choose(selectionCount: 2, envelope: open, sidebarFolder: inbox),
            .selection(count: 2)
        )
        XCTAssertEqual(
            MailReaderChoice.choose(selectionCount: 22, envelope: nil, sidebarFolder: inbox),
            .selection(count: 22)
        )
    }

    func testOneSelectedWithAMessageIsTheReader() {
        let open = TestFixtures.makeEnvelope(uid: 7).inFolder("INBOX")
        XCTAssertEqual(
            MailReaderChoice.choose(selectionCount: 1, envelope: open, sidebarFolder: inbox),
            .reader(folder: inbox, envelope: open)
        )
    }

    /// A cross-folder search result opens against its true mailbox, not the
    /// sidebar's folder.
    func testAMessageOpensAgainstItsOwnFolder() {
        let open = TestFixtures.makeEnvelope(uid: 7).inFolder("Archive")
        XCTAssertEqual(
            MailReaderChoice.choose(selectionCount: 0, envelope: open, sidebarFolder: inbox),
            .reader(folder: Folder(path: "Archive"), envelope: open)
        )
    }

    func testAMessageWithNoFolderOpensAgainstTheSidebar() {
        let open = TestFixtures.makeEnvelope(uid: 7)
        XCTAssertEqual(
            MailReaderChoice.choose(selectionCount: 0, envelope: open, sidebarFolder: inbox),
            .reader(folder: inbox, envelope: open)
        )
    }

    func testNoMessageIsTheEmptyPrompt() {
        XCTAssertEqual(MailReaderChoice.choose(selectionCount: 0, envelope: nil, sidebarFolder: inbox), .empty)
        XCTAssertEqual(MailReaderChoice.choose(selectionCount: 1, envelope: nil, sidebarFolder: inbox), .empty)
    }

    func testNoFolderAnywhereIsTheEmptyPrompt() {
        let open = TestFixtures.makeEnvelope(uid: 7)
        XCTAssertEqual(MailReaderChoice.choose(selectionCount: 0, envelope: open, sidebarFolder: nil), .empty)
    }
}
