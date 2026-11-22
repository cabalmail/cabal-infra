import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The mail transitions of one window (`MailNavigationState`): what each
/// does to the folder, the open message and the collapsed column, and what
/// it hands `SceneNavigator` to apply. The navigator's own suites
/// (`SceneNavigator*Tests`) check that those records reach the route, the
/// resume session and the folder list's hold.
final class MailNavigationStateTests: XCTestCase {
    private let tree = UUID()
    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
    private let other = TestFixtures.makeEnvelope(uid: 12, messageId: "<twelve@example.com>")

    private var messageRef: MessageRef { message.ref(defaultFolder: "INBOX") }

    /// A state whose place belongs to `tree`, on INBOX's list.
    private func onInbox() -> MailNavigationState {
        var state = MailNavigationState()
        _ = state.appear(tree, startsOnFolderList: false)
        state.mount(tree)
        _ = state.setFolder(inbox)
        return state
    }

    /// `onInbox()` with `message` open in the reader.
    private func reading() -> MailNavigationState {
        var state = onInbox()
        _ = state.openMessage(message, isSearching: false)
        return state
    }

    // MARK: Trees

    /// #1664: until a tree has taken over it sees no folder and no message,
    /// so its list mounts only after the restore it applies is parked.
    func testATreeSeesNothingUntilItHasTakenOver() {
        var state = reading()
        let rebuilt = UUID()

        XCTAssertTrue(state.appear(rebuilt, startsOnFolderList: false), "a second tree replaces the first")
        XCTAssertNil(state.folder(in: rebuilt))
        XCTAssertNil(state.envelope(in: rebuilt))
        XCTAssertEqual(state.column(in: rebuilt), .sidebar)
        XCTAssertEqual(state.folder(in: tree), inbox, "the tree being replaced still draws the place")

        state.mount(rebuilt)

        XCTAssertEqual(state.folder(in: rebuilt), inbox)
        XCTAssertEqual(state.envelope(in: rebuilt), message)
        XCTAssertEqual(state.column(in: rebuilt), .detail)
        XCTAssertNil(state.folder(in: tree), "the place has one owner")
        XCTAssertNil(state.envelope(in: tree))
        XCTAssertEqual(state.column(in: tree), .sidebar)
    }

    func testOnlyATreeThatReplacesAnotherIsARebuild() {
        var state = MailNavigationState()

        XCTAssertFalse(state.appear(tree, startsOnFolderList: false), "the window's first tree")
        state.mount(tree)
        XCTAssertFalse(state.appear(tree, startsOnFolderList: false), "the same tree back from a tab switch")
        XCTAssertTrue(state.appear(UUID(), startsOnFolderList: false))
    }

    func testTheGateKnowsTheTreeAppearingTheOneItReplacedAndHowItStarts() {
        var state = onInbox()
        let rebuilt = UUID()

        _ = state.appear(rebuilt, startsOnFolderList: true)

        XCTAssertTrue(state.isAppearing(rebuilt))
        XCTAssertFalse(state.isAppearing(tree))
        XCTAssertTrue(state.isSuperseded(tree))
        XCTAssertFalse(state.isSuperseded(rebuilt))
        XCTAssertTrue(state.gate.startsOnFolderList)
    }

    /// Writes from the tree a swap is tearing down are dropped, and so are
    /// writes from the new tree until it has taken over.
    func testNeitherTreeWritesWhileASwapIsUnderWay() {
        var state = reading()
        let rebuilt = UUID()
        _ = state.appear(rebuilt, startsOnFolderList: false)
        let before = state

        XCTAssertEqual(state.selectMessage(other, isSearching: false, from: tree), [])
        XCTAssertEqual(state.selectMessage(nil, isSearching: false, from: rebuilt), [])
        XCTAssertEqual(state.setColumn(.content, isSearching: false, from: tree), [])
        XCTAssertEqual(state.setColumn(.content, isSearching: false, from: rebuilt), [])
        XCTAssertEqual(state, before)

        state.mount(rebuilt)

        XCTAssertEqual(
            state.selectMessage(other, isSearching: false, from: rebuilt),
            [.searchResult(nil), .message(other.ref(defaultFolder: "INBOX"))]
        )
        XCTAssertEqual(state.selectMessage(nil, isSearching: false, from: tree), [], "the old tree stays shut out")
    }

    /// A rebuilt tree renders the place: the folder stays, the open message
    /// goes with the old list for the new one to reselect, and the column
    /// starts on the folder's list. The window has not moved, so the
    /// hand-off returns nothing to record.
    func testAHandOffKeepsTheFolderDropsTheMessageAndStartsOnItsList() {
        var state = reading()

        state.handOff()

        XCTAssertEqual(state.folder, inbox)
        XCTAssertNil(state.envelope)
        XCTAssertEqual(state.column, .content)
    }

    func testAHandOffWithNoFolderStartsOnTheFolderList() {
        var state = reading()
        _ = state.setFolder(nil)
        _ = state.openMessage(message, isSearching: true)

        state.handOff()

        XCTAssertNil(state.envelope)
        XCTAssertEqual(state.column, .sidebar)
    }

    // MARK: Folder

    func testANewFolderClosesTheMessageShowsItsListAndMovesTheSession() {
        var state = reading()

        let records = state.setFolder(archive)

        XCTAssertEqual(records, [.folder(path: "Archive"), .sessionFolder(path: "Archive")])
        XCTAssertEqual(state.folder, archive)
        XCTAssertNil(state.envelope, "the message went with the old folder")
        XCTAssertEqual(state.column, .content, "the list, never the reader")
    }

    /// Only a landing before the window has shown mail passes false:
    /// recording there would move the session out of Feeds.
    func testALandingThatDoesNotMoveTheSessionStillMovesTheWindow() {
        var state = MailNavigationState()

        XCTAssertEqual(state.setFolder(inbox, movesSession: false), [.folder(path: "INBOX")])
        XCTAssertEqual(state.folder, inbox)
        XCTAssertEqual(state.column, .content)
    }

    func testClearingTheFolderShowsTheFolderListAndMovesNoSession() {
        var state = reading()

        XCTAssertEqual(state.setFolder(nil), [.folder(path: nil)])
        XCTAssertNil(state.folder)
        XCTAssertNil(state.envelope)
        XCTAssertEqual(state.column, .sidebar)
    }

    /// #1535: the stand-in a navigate request selected is swapped for the
    /// fetched folder of the same path. Same mailbox, so the message stays
    /// and nothing is recorded again.
    func testAFolderOfTheSamePathIsSwappedInWithoutMovingAnything() {
        var state = MailNavigationState()
        _ = state.appear(tree, startsOnFolderList: false)
        state.mount(tree)
        _ = state.setFolder(Folder(path: "INBOX"))
        _ = state.openMessage(message, isSearching: false)

        XCTAssertEqual(state.setFolder(inbox), [])
        XCTAssertEqual(state.folder, inbox, "the fetched folder, with its subscription")
        XCTAssertEqual(state.envelope, message)
        XCTAssertEqual(state.column, .detail)
        XCTAssertEqual(state.setFolder(inbox), [], "and the same folder again is nothing at all")
    }

    // MARK: Message

    func testOpeningAMessagePushesTheReaderAndRecordsItInTheSidebarsFolder() {
        var state = onInbox()

        let records = state.openMessage(message, isSearching: false)

        XCTAssertEqual(records, [.searchResult(nil), .message(messageRef)])
        XCTAssertEqual(messageRef.folder, "INBOX")
        XCTAssertEqual(state.envelope, message)
        XCTAssertEqual(state.column, .detail)
        XCTAssertEqual(state.openMessage(message, isSearching: false), [], "the same message again records nothing")
    }

    /// The message being read is gone (a send, archive or move from the
    /// reader): a collapsed navigation pops back to the list.
    func testClosingTheMessageRecordsItAndFallsBackToTheList() {
        var state = reading()

        XCTAssertEqual(
            state.openMessage(nil, isSearching: false),
            [.searchResult(nil), .noMessage(folderPath: "INBOX")]
        )
        XCTAssertNil(state.envelope)
        XCTAssertEqual(state.column, .content)
    }

    /// Anchored to the sidebar's folder: a row from another folder opens,
    /// but it is not this folder's position.
    func testAMessageFromAnotherFolderOpensButIsNotThisFoldersPosition() {
        var state = onInbox()
        let elsewhere = message.inFolder("Archive")

        XCTAssertEqual(state.openMessage(elsewhere, isSearching: false), [.searchResult(nil)])
        XCTAssertEqual(state.envelope, elsewhere)
        XCTAssertEqual(state.column, .detail)
    }

    /// While searching, the open message is a result with no single folder
    /// to anchor the cursor to: it is kept for a layout swap to hand on
    /// (#2184), and the route and cursor stay where they were.
    func testASearchResultIsHandedOnAndRecordsNoPosition() {
        var state = onInbox()
        let result = message.inFolder("INBOX")

        XCTAssertEqual(state.openMessage(result, isSearching: true), [.searchResult(result)])
        XCTAssertEqual(state.envelope, result)
        XCTAssertEqual(state.column, .detail)
        XCTAssertEqual(state.openMessage(nil, isSearching: true), [.searchResult(nil)])
    }

    func testWithNoFolderAMessageOpensAndRecordsNoPosition() {
        var state = MailNavigationState()

        XCTAssertEqual(state.openMessage(message, isSearching: false), [.searchResult(nil)])
        XCTAssertEqual(state.envelope, message)
    }

    // MARK: Column

    /// Backing out of the reader drops the message, so the same row can be
    /// opened again.
    func testLeavingTheReaderDropsTheMessage() {
        var state = reading()

        XCTAssertEqual(
            state.setColumn(.content, isSearching: false, from: tree),
            [.searchResult(nil), .noMessage(folderPath: "INBOX")]
        )
        XCTAssertNil(state.envelope)
        XCTAssertEqual(state.column, .content)
        XCTAssertEqual(state.folder, inbox, "the folder stays selected")
    }

    /// Back at the folder list the folder is still selected, which is why
    /// the column is stored; the list's place is let go before anything the
    /// closing message records.
    func testBackingOutToTheFolderListLetsGoOfTheListsPlaceFirst() {
        var fromList = onInbox()
        XCTAssertEqual(fromList.setColumn(.sidebar, isSearching: false, from: tree), [.backedOut])
        XCTAssertEqual(fromList.column, .sidebar)
        XCTAssertEqual(fromList.folder, inbox)
        XCTAssertEqual(
            fromList.setColumn(.sidebar, isSearching: false, from: tree), [],
            "already on the folder list: nothing more to let go of"
        )

        var fromReader = reading()
        XCTAssertEqual(
            fromReader.setColumn(.sidebar, isSearching: false, from: tree),
            [.backedOut, .searchResult(nil), .noMessage(folderPath: "INBOX")]
        )
        XCTAssertNil(fromReader.envelope)
        XCTAssertEqual(fromReader.column, .sidebar)
    }

    func testMovingToTheReaderKeepsTheMessageAndTheColumnOnScreenIsNoMove() {
        var state = reading()
        _ = state.setColumn(.content, isSearching: false, from: tree)
        _ = state.openMessage(message, isSearching: false)
        XCTAssertEqual(state.column, .detail)

        XCTAssertEqual(state.setColumn(.detail, isSearching: false, from: tree), [], "already on the reader")
        XCTAssertEqual(state.envelope, message)

        var onList = onInbox()
        XCTAssertEqual(onList.setColumn(.detail, isSearching: false, from: tree), [], "the reader drops nothing")
        XCTAssertEqual(onList.column, .detail)
        XCTAssertEqual(onList.setColumn(.content, isSearching: false, from: tree), [], "no message left to close")
        XCTAssertEqual(onList.column, .content)
    }

    func testLeavingASearchResultClosesItWithoutACursorRecord() {
        var state = onInbox()
        _ = state.openMessage(message, isSearching: true)

        XCTAssertEqual(state.setColumn(.content, isSearching: true, from: tree), [.searchResult(nil)])
        XCTAssertNil(state.envelope)
    }
}
