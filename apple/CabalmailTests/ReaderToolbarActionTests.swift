import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #836: opening a message in Drafts used to
// ADD "Edit Draft" to the reader toolbar, taking the iPhone bottom bar to
// eight items. That row sizes to its content and neither scrolls nor
// compacts, so the extra item spilled ~23pt off each end and clipped
// "Edit Draft" and "More actions" to ~5pt slivers at the screen edges.
// The fix swaps Edit Draft into the Reply slot, which keeps the count at
// seven in every folder.
@MainActor
final class ReaderToolbarActionTests: XCTestCase {

    private func makeModel(folderPath: String) throws -> MessageDetailViewModel {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let folder = Folder(path: folderPath, attributes: [], isSubscribed: true)
        return MessageDetailViewModel(
            folder: folder,
            envelope: TestFixtures.makeEnvelope(uid: 7),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
    }

    func testDraftsFolderSwapsReplyForEditDraft() throws {
        let model = try makeModel(folderPath: "Drafts")

        XCTAssertTrue(model.isDraftsFolder)
        XCTAssertEqual(
            model.leadingToolbarAction,
            .editDraft,
            "Drafts must show Edit Draft in the leading slot, not alongside Reply"
        )
    }

    func testNonDraftFoldersKeepReply() throws {
        for path in ["INBOX", "Sent", "Trash", "Drafts.Old"] {
            let model = try makeModel(folderPath: path)

            XCTAssertFalse(model.isDraftsFolder, "\(path) is not the Drafts mailbox")
            XCTAssertEqual(
                model.leadingToolbarAction,
                .reply,
                "\(path) must keep Reply in the leading toolbar slot"
            )
        }
    }
}
