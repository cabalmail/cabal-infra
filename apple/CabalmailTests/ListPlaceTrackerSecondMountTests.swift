import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder list whose load task is cancelled under it, which is how a
/// compact folder pick mounts one: the view is built twice, the first
/// mount's `.task` is cancelled, and the load it started reports back —
/// through that cancelled task — to the list that is on screen. The
/// landing has to happen on that report, since the second mount keeps the
/// model the first load produced and so never asks again, and an unlanded
/// list records nothing as it scrolls (#2030).
@MainActor
final class ListPlaceTrackerSecondMountTests: XCTestCase {
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

    /// `land` as the view's load task calls it once that task has been
    /// cancelled: the load outlives the cancellation, so the call is made
    /// from a task that is already cancelled.
    private func landFromACancelledTask(_ model: MessageListViewModel) async {
        let task = Task { @MainActor [tracker, navigator] in
            while !Task.isCancelled { await Task.yield() }
            tracker?.land(model: model, in: navigator)
        }
        task.cancel()
        await task.value
    }

    /// The reported case: the list is on screen, its load reports through
    /// the cancelled task, and it lands and keeps the place from then on.
    func testALoadReportingThroughACancelledTaskLandsAListOnScreen() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))
        tracker.appeared(model, in: navigator)

        await landFromACancelledTask(model)

        XCTAssertEqual(tracker.scrollRequest?.row, 100)
        XCTAssertEqual(place, try anchor(index: 100, uid: 900))
        XCTAssertNil(navigator.restores.pendingListAnchor, "taken")
    }

    /// The symptom itself: a folder picked after launch has nothing parked,
    /// so the landing records nothing — but the list has landed, so the
    /// scroll that follows is the place, which is what a relaunch reopens.
    func testAListLandedFromACancelledTaskRecordsWhereItScrolls() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        await landFromACancelledTask(model)

        tracker.scrolled(toRow: 30, model: model)

        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
    }

    /// A list that has not been asked to land does not land on its own: the
    /// view asks once its initial load has run, which is what keeps a
    /// landing from reaching for rows that are not there yet.
    func testAnAppearAloneDoesNotLand() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))

        tracker.appeared(model, in: navigator)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try anchor(index: 100, uid: 900), "still parked")
    }
}
