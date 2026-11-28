import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the Message menu's item commands act on, and what its Move does,
/// while a search's sectioned results are up (`SearchItemCommands`). On
/// the Mac the menu was live there with a message open and did nothing:
/// the list that answers it is mounted only under the Mail scope. These
/// hold which message a command is for and what a move comes to; the
/// modifier's part is to pass the reader's message in.
@MainActor
final class SearchItemCommandsTests: XCTestCase {
    private var fixture: SearchFixture!

    override func setUp() async throws {
        fixture = try await SearchFixture()
        try await fixture.addArticle("a", day: 3, title: "Ferry timetable")
        await fixture.imap.scriptSearch(SearchFixture.mailResult([4, 3]))
        await fixture.submit("ferry")
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var model: MessageListViewModel { fixture.model }
    private var actions: SearchRowActions {
        SearchRowActions(model: model, place: fixture.place, preferences: fixture.preferences)
    }

    func testACommandIsForTheOpenMessageAsItStandsNowSoASecondPressUndoesTheFirst() async throws {
        // What the reader was handed when the message was opened.
        let opened = try XCTUnwrap(model.envelopes.first)
        XCTAssertFalse(opened.flags.contains(.seen))

        let first = try XCTUnwrap(actions.commandTarget(opened))
        await model.toggleSeen(first)
        let second = try XCTUnwrap(actions.commandTarget(opened))
        XCTAssertTrue(second.flags.contains(.seen), "the row as the model holds it, not as it was opened")
        await model.toggleSeen(second)

        let calls = await fixture.imap.flagCalls
        XCTAssertEqual(calls.map(\.operation), [.add, .remove])
        XCTAssertEqual(calls.map(\.folder), ["INBOX", "INBOX"])
        XCTAssertEqual(calls.map(\.uids), [[4], [4]])
    }

    func testUnderMailTheListAnswersTheMenuAndWithNothingOpenNothingDoes() async throws {
        let opened = try XCTUnwrap(model.envelopes.first)
        XCTAssertNil(actions.commandTarget(nil))

        await fixture.place.pick(.feeds)
        XCTAssertNotNil(actions.commandTarget(opened), "a message stays open in the reader under Feeds")

        await fixture.place.pick(.mail)
        XCTAssertNil(actions.commandTarget(opened), "the mail list is mounted and answers on its selection")
    }

    func testAMessageOpenThatTheResultsNoLongerHoldIsStillTheCommands() async throws {
        let elsewhere = Envelope(uid: 99, subject: "gone", from: [], flags: [.seen], folder: "Archive")

        XCTAssertEqual(actions.commandTarget(elsewhere)?.uid, 99)
    }

    func testAMoveTakesTheMessageOutOfItsOwnFolderAndSaysItHasGone() async throws {
        let opened = try XCTUnwrap(model.envelopes.first)

        let gone = await actions.move(opened, to: "Projects")

        XCTAssertTrue(gone, "the reader showing it closes")
        let moves = await fixture.imap.moveCalls
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.folder, "INBOX")
        XCTAssertEqual(moves.first?.uids, [4])
        XCTAssertEqual(moves.first?.destination, "Projects")
        XCTAssertEqual(model.envelopes.map(\.uid), [3])
    }

    func testAMoveToTheFolderTheMessageIsInSendsNothingAndLeavesItOpen() async throws {
        let opened = try XCTUnwrap(model.envelopes.first)

        let gone = await actions.move(opened, to: "INBOX")

        XCTAssertFalse(gone)
        let moves = await fixture.imap.moveCalls
        XCTAssertEqual(moves.count, 0)
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3])
    }
}
