import XCTest
@testable import Cabalmail

// The new-folder sheet's input lives in `NewFolderForm`, held by the view
// that presents the sheet — the sheet's own state doesn't survive SwiftUI
// re-creating its body when the parent picker's menu dismisses. These cover
// what that type owes the sheet: the picker's top-level sentinel, the
// enable rule behind Create, and the per-presentation clear.
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
}
