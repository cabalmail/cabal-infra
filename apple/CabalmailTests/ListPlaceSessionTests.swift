import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder list's recorded place reaches the resume session
/// (`ListPlaceTracker` through `WindowRecorder.listPlace`), for the next
/// launch: from the window last used only, and only what the list itself
/// recorded for its window.
@MainActor
final class ListPlaceSessionTests: XCTestCase {
    private var world: ListPagingWorld!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var coordinator: NavStateCoordinator!
    private var lastUsed: UUID?

    override func setUp() async throws {
        try await super.setUp()
        world = ListPagingWorld()
        suiteName = "ListPlaceSessionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let store = ResumeSessionStore(defaults: defaults)
        store.saveSession(ResumeSession(section: .mail, folder: ListPagingWorld.folderPath))
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
        coordinator = nil
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func anchor(index: Int, uid: UInt32) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: ListPagingWorld.folderPath, messageID: ListPagingWorld.messageID(uid), uid: uid, index: index
        ))
    }

    /// A list landed in a window, and what drives it.
    private struct LandedList {
        let navigator: SceneNavigator
        let tracker: ListPlaceTracker
        let model: MessageListViewModel
    }

    /// A window on the session's coordinator, and a list landed in it.
    private func windowWithALandedList() async throws -> LandedList {
        let coordinator = try XCTUnwrap(coordinator)
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .mail,
            lastUsedWindow: { [unowned self] in self.lastUsed }
        )
        navigator.windowID = UUID()
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        let tracker = ListPlaceTracker()
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        return LandedList(navigator: navigator, tracker: tracker, model: model)
    }

    func testAScrolledListsPlaceIsTheSessions() async throws {
        let list = try await windowWithALandedList()

        list.tracker.scrolled(toRow: 30, model: list.model)
        XCTAssertEqual(coordinator.session.listAnchor, try anchor(index: 30, uid: 970))

        list.tracker.scrolled(toRow: 0, model: list.model)
        XCTAssertNil(coordinator.session.listAnchor, "back at the top")
    }

    func testAListInAWindowThatIsNotLastUsedLeavesTheSessionAlone() async throws {
        let list = try await windowWithALandedList()
        lastUsed = UUID()

        list.tracker.scrolled(toRow: 30, model: list.model)

        XCTAssertNil(coordinator.session.listAnchor)
        XCTAssertEqual(list.navigator.listHold.place, try anchor(index: 30, uid: 970), "the window keeps its own")
    }

    /// The landing itself puts the place it found into the session: the
    /// message the last run left at the top, at the row it has now.
    func testALandingRecordsWhereItFoundThePlace() async throws {
        let coordinator = try XCTUnwrap(coordinator)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let model = try await world.openedList(size: 1003, preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))
        let tracker = ListPlaceTracker()

        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)

        XCTAssertEqual(coordinator.session.listAnchor, try anchor(index: 103, uid: 900))
    }

    /// A list that has not moved writes nothing: a relaunch that changed
    /// nothing leaves the session's place as the last run left it.
    func testAListThatDoesNotMoveLeavesTheSessionsPlace() async throws {
        coordinator.recordListAnchor(try anchor(index: 60, uid: 940), folderPath: ListPagingWorld.folderPath)

        let list = try await windowWithALandedList()
        list.tracker.loadsChanged(model: list.model)

        XCTAssertEqual(coordinator.session.listAnchor, try anchor(index: 60, uid: 940))
    }
}
