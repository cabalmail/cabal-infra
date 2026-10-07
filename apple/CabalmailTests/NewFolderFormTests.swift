import XCTest
import CabalmailKit
@testable import CabalmailUI

// The new-folder sheet's input lives in `NewFolderForm`, held by the view
// that presents the sheet — the sheet's own state doesn't survive SwiftUI
// re-creating its body when the parent picker's menu dismisses. These cover
// what that type owes the sheet: the picker's top-level sentinel, the
// enable rule behind Create, the per-presentation clear, and why the last
// Create failed (#1915).
final class NewFolderFormTests: XCTestCase {

    func testTypedNameAndChosenParentBothSurviveTheFormOutlivingTheSheet() {
        let form = NewFolderForm()
        form.name = "kid"
        form.parent = "INBOX"

        // Standing in for the sheet body being rebuilt around the form:
        // whatever the view does, the input is still here to submit.
        XCTAssertEqual(form.name, "kid")
        XCTAssertEqual(form.chosenParent, "INBOX")
        XCTAssertTrue(form.canCreate)
    }

    func testEmptyParentMeansTopLevel() {
        let form = NewFolderForm()
        form.name = "kid"
        XCTAssertNil(form.chosenParent, "the picker's 'None (top level)' row carries an empty tag")
    }

    func testWhitespaceOnlyNameCannotCreate() {
        let form = NewFolderForm()
        XCTAssertFalse(form.canCreate, "an untouched form has nothing to create")
        form.name = "   "
        XCTAssertFalse(form.canCreate)
        form.name = " kid "
        XCTAssertTrue(form.canCreate)
    }

    func testResetClearsBothFieldsForTheNextPresentation() {
        let form = NewFolderForm()
        form.name = "kid"
        form.parent = "INBOX"

        form.reset()

        XCTAssertEqual(form.name, "")
        XCTAssertNil(form.chosenParent, "a reopened sheet starts at top level")
        XCTAssertFalse(form.canCreate)
    }

    // MARK: - A failed create is shown on the sheet (#1915)

    @MainActor
    func testAFailedCreateKeepsTheSheetOpenWithItsSentence() async {
        let form = NewFolderForm()
        form.name = "INBOX"
        let failure = CabalmailError.network("The Internet connection appears to be offline.")

        let canClose = await form.submit { _, _ in throw failure }

        XCTAssertFalse(canClose)
        XCTAssertEqual(form.errorMessage, failure.localizedDescription)
        XCTAssertEqual(form.name, "INBOX", "the typed name stays for another try")
    }

    @MainActor
    func testASuccessfulCreateClosesTheSheetAndClearsAnEarlierFailure() async {
        let form = NewFolderForm()
        form.name = " kid "
        form.parent = "INBOX"
        _ = await form.submit { _, _ in throw CabalmailError.network("offline") }
        var submitted: (name: String, parent: String?)?

        let canClose = await form.submit { submitted = ($0, $1) }

        XCTAssertTrue(canClose)
        XCTAssertNil(form.errorMessage)
        XCTAssertEqual(submitted?.name, " kid ", "the model trims, not the form")
        XCTAssertEqual(submitted?.parent, "INBOX")
    }

    @MainActor
    func testResetClearsALastFailureForTheNextPresentation() async {
        let form = NewFolderForm()
        _ = await form.submit { _, _ in throw CabalmailError.network("offline") }

        form.reset()

        XCTAssertNil(form.errorMessage)
    }

    /// The sidebar's error line sits behind the sheet, so the failure goes to
    /// the sheet and not there.
    @MainActor
    func testAFailedCreateIsThrownNotWrittenBehindTheSheet() async throws {
        // `FakeImapClient` answers `createFolder` with an error.
        let sidebar = FolderListViewModel(client: try TestFixtures.makeClient(imap: FakeImapClient()),
                                          mailStore: AppState().mailStore)

        do {
            try await sidebar.createFolder(name: "Projects", parent: nil)
            XCTFail("a failed create returned normally")
        } catch {
            XCTAssertTrue(error is CabalmailError, "\(error)")
        }
        XCTAssertNil(sidebar.errorMessage)
    }
}
