import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Defect 11 of the 2026-10 rearchitecture audit: menu commands and drag-
/// moves reached every mounted list and reader in every main window. A menu
/// command now goes to the window in front's own `WindowCommands`, a compose
/// request goes to the one window it names (`ComposeCoordinator`), and a
/// drag names its source list; these pin those rules.
@MainActor
final class CommandWindowTargetingTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    private func makeWindow() -> WindowCommands {
        WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
    }

    func testACommandSentToOneWindowReachesOnlyThatWindow() {
        let commandsA = makeWindow()
        let commandsB = makeWindow()
        commandsA.send(.reply)
        XCTAssertEqual(commandsA.count(of: .reply), 1)
        XCTAssertEqual(commandsB.count(of: .reply), 0, "a second window must not answer (two replies)")
    }

    func testEveryCommandStaysWithTheWindowItWasSentTo() {
        let commandsA = makeWindow()
        let commandsB = makeWindow()
        commandsA.send(.toggleSeen)
        commandsB.send(.refresh)
        commandsB.send(.feed(.refresh))
        commandsA.send(.sidebarTree(.expandAllFolders))
        XCTAssertEqual([commandsA.count(of: .toggleSeen), commandsA.count(of: .refresh)], [1, 0])
        XCTAssertEqual(commandsA.count(of: .feed(.refresh)) + commandsB.count(of: .sidebarTree(.expandAllFolders)), 0)
        let appState = AppState()
        let surfaceA = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let surfaceB = RecordingComposeSurface(window: windowB).register(with: appState.compose)
        appState.compose.open(seed: Draft(), from: windowB)
        XCTAssertEqual([surfaceA.shown.count, surfaceB.shown.count], [0, 1])
    }

    /// Fixed in #1824 (the defect `CommandHandoffCharacterizationTests`'
    /// mailto row pinned): an untargeted compose reached every window. It
    /// opens in one, and a surface outside any main window is shown only a
    /// compose that names no window.
    func testAnUntargetedComposeReachesOneWindow() {
        let appState = AppState()
        let outside = RecordingComposeSurface(window: nil).register(with: appState.compose)
        let surfaceA = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let surfaceB = RecordingComposeSurface(window: windowB).register(with: appState.compose)
        appState.compose.open(seed: Draft(), from: nil)
        XCTAssertEqual([outside.shown.count, surfaceA.shown.count, surfaceB.shown.count], [0, 0, 1])
        appState.compose.open(seed: Draft(), from: windowA)
        XCTAssertEqual([outside.shown.count, surfaceA.shown.count, surfaceB.shown.count], [0, 1, 1])
    }

    /// The main window last in front, which a mailto compose is aimed at:
    /// closing another window keeps it.
    func testTheMainWindowLastInFrontSurvivesAnotherWindowClosing() {
        let appState = AppState()
        appState.noteActiveMainWindow(windowA)
        appState.forgetMainWindow(windowB)
        XCTAssertEqual(appState.lastActiveMainWindow, windowA, "closing another window keeps it")
        appState.forgetMainWindow(windowA)
        XCTAssertNil(appState.lastActiveMainWindow)
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
