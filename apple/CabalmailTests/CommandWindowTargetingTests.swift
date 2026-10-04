import XCTest
import CabalmailKit
@testable import Cabalmail

/// Defect 11 of the 2026-10 rearchitecture audit: menu commands and drag-
/// moves reached every mounted list and reader in every main window. A
/// command now names its window and a drag names its source list; these
/// pin the rules the observers apply to those names.
@MainActor
final class CommandWindowTargetingTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    func testACommandAimedAtOneWindowReachesOnlyThatWindow() {
        let appState = AppState()
        appState.requestReply(in: windowA)
        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertFalse(appState.commandReaches(windowB), "a second window must not answer (two replies)")
    }

    func testEveryTickRecordsItsOwnTarget() {
        // A later untargeted request (a push action's refresh) must not
        // inherit the previous command's window.
        let appState = AppState()
        appState.requestToggleSeen(in: windowA)
        appState.requestRefresh()
        XCTAssertTrue(appState.commandReaches(windowB))
        appState.requestFeedCommand(.refresh, in: windowB)
        XCTAssertFalse(appState.commandReaches(windowA))
        appState.requestSidebarTree(.expandAllFolders, in: windowA)
        XCTAssertFalse(appState.commandReaches(windowB))
        appState.requestCompose(seed: Draft(), in: windowB)
        XCTAssertFalse(appState.commandReaches(windowA))
    }

    func testAnUntargetedCommandReachesEveryWindow() {
        // Empty Trash and push actions refresh whatever is showing anywhere.
        let appState = AppState()
        appState.requestRefresh()
        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertTrue(appState.commandReaches(windowB))
    }

    func testAViewOutsideAMainWindowAnswersAsBefore() {
        let appState = AppState()
        appState.requestReply(in: windowA)
        XCTAssertTrue(appState.commandReaches(nil))
    }

    func testAMenuCommandFallsBackToTheMainWindowLastInFront() {
        // While a compose window is key there is no focused main window.
        let appState = AppState()
        XCTAssertNil(appState.menuCommandTarget(focused: nil))
        appState.noteActiveMainWindow(windowA)
        XCTAssertEqual(appState.menuCommandTarget(focused: nil), windowA)
        XCTAssertEqual(appState.menuCommandTarget(focused: windowB), windowB, "the focused window wins")
        appState.forgetMainWindow(windowB)
        XCTAssertEqual(appState.menuCommandTarget(focused: nil), windowA, "closing another window keeps it")
        appState.forgetMainWindow(windowA)
        XCTAssertNil(appState.menuCommandTarget(focused: nil))
    }

    func testOnlyTheSourceListPerformsADragMove() throws {
        let source = UUID()
        let item = MessageDragItem(uid: 7, sourceFolder: "INBOX")
        let appState = AppState()
        appState.requestMove(items: [item], to: "Archive", from: source)
        let request = try XCTUnwrap(appState.pendingMoveRequest)
        XCTAssertTrue(request.isPerformed(by: source))
        XCTAssertFalse(request.isPerformed(by: UUID()), "another list would send the move twice")
    }

    func testADragMoveWithoutASourceIsPerformedByAnyList() {
        let request = MessageMoveRequest(destination: "Archive", items: [], sourceList: nil, tick: 1)
        XCTAssertTrue(request.isPerformed(by: UUID()))
    }

    func testTheDragPayloadCarriesItsSourceList() throws {
        let source = UUID()
        let payload = MessageDragPayload(items: [MessageDragItem(uid: 7, sourceFolder: "INBOX")], sourceList: source)
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(MessageDragPayload.self, from: data).sourceList, source)
    }

    func testAPayloadWithoutASourceListStillDecodes() throws {
        let data = Data(#"{"items":[{"uid":7,"sourceFolder":"INBOX"}]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MessageDragPayload.self, from: data).sourceList)
    }
}
