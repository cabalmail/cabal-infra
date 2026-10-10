import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Who wins when a folder list's landing meets something else
/// (`ListPlaceTracker`): the user's own scroll, before the landing or while
/// it waits, is never undone; a list left behind by a swap or a folder
/// change neither lands nor takes its successor's claim; and a list back
/// from a pill or an error row records where it is then.
@MainActor
final class ListPlaceTrackerTakeoverTests: XCTestCase {
    private var world: ListPagingWorld!
    private var navigator: SceneNavigator!
    private var tracker: ListPlaceTracker!

    override func setUp() async throws {
        try await super.setUp()
        world = ListPagingWorld()
        navigator = SceneNavigator(coordinator: { nil }, hasClient: { true }, seed: .mail)
        tracker = ListPlaceTracker()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
        navigator = nil
        tracker = nil
        try await super.tearDown()
    }

    private func anchor(index: Int, uid: UInt32) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: ListPagingWorld.folderPath, messageID: ListPagingWorld.messageID(uid), uid: uid, index: index
        ))
    }

    private var place: ListAnchor? { navigator.listHold.place }

    // MARK: The user's scroll

    /// The cached rows are on screen while the first refresh is out, and the
    /// user starts scrolling. The landing does not pull the list away: the
    /// parked place is spent, and the place is where the user is.
    func testAListTheUserScrolledBeforeItLandedIsNotMoved() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        tracker.appeared(model, in: navigator)
        tracker.userScrolled()
        tracker.scrolled(toRow: 30, model: model)
        XCTAssertNil(place, "nothing records before the landing")

        tracker.land(model: model, in: navigator)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
        XCTAssertNil(navigator.restores.pendingListAnchor, "spent")
    }

    /// Offline, the landing waits for the folder's count. The user scrolls
    /// the cached rows meanwhile: the count arriving moves nothing, and the
    /// place is where they are.
    func testAWaitingLandingGivesWayToTheUsersScroll() async throws {
        await world.imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let rows = ListPagingWorld.serverFolder(size: 1000, stampsMessageIDs: true)
        let model = try world.makeModel(preloaded: Array(rows.prefix(50)))
        await model.refresh()
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        XCTAssertEqual(place, try anchor(index: 400, uid: 600), "precondition: waiting")

        tracker.userScrolled()
        tracker.scrolled(toRow: 20, model: model)
        await world.scriptServer(size: 1000, stampsMessageIDs: true)
        await model.refresh()
        tracker.loadsChanged(model: model)

        XCTAssertNil(tracker.scrollRequest, "no jump to the old place")
        XCTAssertEqual(place, try anchor(index: 20, uid: 980))
    }

    /// A landing that waits keeps its anchor through a move that is not the
    /// user's (a layout pass): only the saved count is showing, with no
    /// error row above the rows.
    func testAWaitingLandingKeepsItsAnchorThroughALayoutPass() async throws {
        let rows = ListPagingWorld.serverFolder(size: 1000, stampsMessageIDs: true)
        let model = try world.makeModel(preloaded: Array(rows.prefix(50)))
        model.window?.savedMessageCount = 1000
        XCTAssertNil(model.errorMessage, "precondition: no error row")
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        XCTAssertNil(tracker.scrollRequest, "precondition: waiting for the count")

        tracker.scrolled(toRow: 1, model: model)
        tracker.scrolled(toRow: 0, model: model)

        XCTAssertEqual(place, try anchor(index: 400, uid: 600))
    }

    // MARK: A list left behind

    /// The old tree's list is still in its first load when a swap builds
    /// its successor, which lands. The old list's load then returns: it
    /// does not land, and the new list keeps recording.
    func testAListLeftBehindByASwapNeitherLandsNorVoidsItsSuccessor() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        navigator.listHold.handOff(isWide: true, folderPath: ListPagingWorld.folderPath, parkingIn: navigator.restores)
        let successor = ListPlaceTracker()
        successor.appeared(model, in: navigator)
        successor.land(model: model, in: navigator)
        XCTAssertEqual(successor.scrollRequest?.row, 200, "precondition: the new list landed")
        successor.scrolled(toRow: 200, model: model)

        tracker.land(model: model, in: navigator)
        successor.scrolled(toRow: 30, model: model)

        XCTAssertNil(tracker.scrollRequest, "the old list does not land")
        XCTAssertEqual(place, try anchor(index: 30, uid: 970), "the new list still records")
    }

    /// The view's load outlives its task: a list whose view has gone, or
    /// that a reader covers, gets its landing from a cancelled task. It
    /// does not land then, and spends nothing; it lands when it is back.
    func testAListWhoseTaskWasCancelledLandsWhenItComesBack() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        tracker.appeared(model, in: navigator)
        let tracker = try XCTUnwrap(tracker)
        let navigator = try XCTUnwrap(navigator)
        let late = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            tracker.land(model: model, in: navigator)
        }
        late.cancel()
        await late.value

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertNotNil(navigator.restores.pendingListAnchor, "not spent")

        tracker.land(model: model, in: navigator)
        XCTAssertEqual(tracker.scrollRequest?.row, 200)
    }

    // MARK: Recording resumes

    /// On a pill the list does not record. Back on All, with the rows
    /// reloaded and the list at its top, the place is the top, not the row
    /// it was at before the pill.
    func testBackFromAPillThePlaceIsWhereTheListIs() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        tracker.scrolled(toRow: 100, model: model)
        XCTAssertEqual(place, try anchor(index: 100, uid: 900), "precondition")

        model.filterTab = .unread
        tracker.scrolled(toRow: 0, model: model)
        XCTAssertEqual(place, try anchor(index: 100, uid: 900), "a pill records nothing")
        model.filterTab = .all
        tracker.loadsChanged(model: model)

        XCTAssertNil(place, "the list is at its top")
    }

    /// A scroll under an error row is not recorded, since the row shifts
    /// the rows below it. When it clears, the place catches up.
    func testWhenTheErrorRowClearsThePlaceCatchesUp() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        tracker.scrolled(toRow: 30, model: model)
        model.errorMessage = "The folder could not be refreshed."
        tracker.scrolled(toRow: 60, model: model)
        XCTAssertEqual(place, try anchor(index: 30, uid: 970), "precondition")

        model.errorMessage = nil
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place, try anchor(index: 60, uid: 940))
    }

    /// The folder's window jumps elsewhere (End) while the scroll view has
    /// not moved yet, so the place's row is no longer loaded. Nothing new is
    /// known about that row: the place keeps naming its message.
    func testAPlaceWhoseRowIsNoLongerLoadedKeepsItsMessage() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        tracker.scrolled(toRow: 100, model: model)
        XCTAssertEqual(place, try anchor(index: 100, uid: 900), "precondition")

        model.window?.ensureLoaded(around: 900)
        await world.settle(model)
        XCTAssertNil(model.envelope(inSlot: 100), "precondition: the window no longer holds the row")
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place, try anchor(index: 100, uid: 900))
    }
}
