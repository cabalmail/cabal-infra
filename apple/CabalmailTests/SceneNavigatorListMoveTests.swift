import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The split's list moving between its column and the panel below a laptop
/// fold (`SceneNavigator.listMoves()`, #1649): the list mounting next takes
/// the window's selection, a single highlighted row included, and its place,
/// and the open message stays open.
@MainActor
final class SceneNavigatorListMoveTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SceneNavigatorListMoveTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// A wide window landed on INBOX, and the tree that landed it.
    private func landed() async throws -> (navigator: SceneNavigator, tree: UUID) {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: true)
        navigator.foldersLoaded([inbox])
        return (navigator, tree)
    }

    private func place(_ index: Int) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: "INBOX", messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// One highlighted row, which a layout swap would not hand over
    /// (`SelectionModel.handOff(toWide:)`), goes with the move: the open
    /// message's row stays highlighted in the panel.
    func testTheMovedListTakesTheWindowsSelectionOnce() async throws {
        let (navigator, _) = try await landed()
        let column = navigator.mailSelection(for: "INBOX")
        column.selected = [MessageRef(folder: "INBOX", uid: 9)]

        navigator.listMoves()

        XCTAssertTrue(navigator.mailSelection(for: "INBOX") === column)
        XCTAssertFalse(navigator.mailSelection(for: "INBOX") === column, "handed to one list")
    }

    func testTheMovedListLandsOnTheWindowsPlaceAndTheOldOneStopsRecording() async throws {
        let (navigator, _) = try await landed()
        let column = navigator.listHold.claim("INBOX", isWide: true)
        XCTAssertTrue(navigator.listHold.record(try place(300), under: column))

        navigator.listMoves()

        // The column list going away scrolls to the top, which is not the place.
        XCTAssertFalse(navigator.listHold.record(nil, under: column))
        let panel = navigator.listHold.claim("INBOX", isWide: true)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: panel, from: navigator.restores), try place(300))
    }

    func testTheOpenMessageStaysOpen() async throws {
        let (navigator, tree) = try await landed()
        navigator.selectMessage(message, isSearching: false, from: tree)

        navigator.listMoves()

        XCTAssertEqual(navigator.envelope(in: tree)?.uid, 9)
        XCTAssertNil(navigator.restores.pendingRestore, "nothing to reselect: the reader never closed")
    }

    /// The selection a move holds is the folder's: a list for another folder
    /// starts afresh.
    func testAListForAnotherFolderStartsAfresh() async throws {
        let (navigator, _) = try await landed()
        let column = navigator.mailSelection(for: "INBOX")

        navigator.listMoves()

        XCTAssertFalse(navigator.mailSelection(for: "Archive") === column)
    }
}
