import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder list recording where it is scrolled for its window
/// (`ListPlaceTracker`), over `ListPagingWorld`'s scripted folder: only a
/// list that has landed, is on screen, shows the folder in its own order
/// with no error row, and still holds its window's claim records; and the
/// move its own landing makes is not a place the user chose.
@MainActor
final class ListPlaceTrackerRecordingTests: XCTestCase {
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

    /// A 1,000-message list with its first 250 rows loaded, landed with
    /// nothing parked.
    private func landedList() async throws -> MessageListViewModel {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        return model
    }

    // MARK: Recording

    func testScrollingRecordsTheTopRowByItsIdentity() async throws {
        let model = try await landedList()

        tracker.scrolled(toRow: 30, model: model)

        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
    }

    func testBackAtTheTopThereIsNoPlace() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)

        tracker.scrolled(toRow: 0, model: model)

        XCTAssertNil(place)
    }

    func testNothingRecordsBeforeTheLanding() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)

        tracker.scrolled(toRow: 30, model: model)

        XCTAssertNil(place)
    }

    /// A reader pushed over the list: whatever the covered list's scroll
    /// view reports is not the user's place.
    func testNothingRecordsOffScreen() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)
        tracker.disappeared()

        tracker.scrolled(toRow: 0, model: model)
        XCTAssertEqual(place, try anchor(index: 30, uid: 970))

        tracker.appeared(model, in: navigator)
        tracker.scrolled(toRow: 31, model: model)
        XCTAssertEqual(place, try anchor(index: 31, uid: 969), "back on screen, it records again")
    }

    /// The error row sits above the rows and shifts them all down, so the
    /// offset no longer says which row is at the top.
    func testAnErrorRowStopsRecording() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)
        model.errorMessage = "The folder could not be refreshed."

        tracker.scrolled(toRow: 60, model: model)

        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
    }

    func testAnotherSortRecordsNothing() async throws {
        let model = try await landedList()
        model.window?.sortCriterion = SortCriterion(field: .subject, direction: .ascending)

        tracker.scrolled(toRow: 30, model: model)

        XCTAssertNil(place)
    }

    // MARK: Identity

    /// A fast scroll onto rows not loaded yet records a row with no
    /// identity; when the row loads, the place names the message there.
    func testAPlaceholderTopRowGainsItsIdentityWhenLoaded() async throws {
        let model = try await world.openedList(stampsMessageIDs: true)
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)

        tracker.scrolled(toRow: 400, model: model)
        XCTAssertEqual(place?.index, 400)
        XCTAssertNil(place?.uid, "precondition: the row is a placeholder")

        model.window?.ensureLoaded(around: 400)
        await world.settle(model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place, try anchor(index: 400, uid: 600))
    }

    /// Mail arrives above a list that has not moved: the row at the top is
    /// another message now, and the place names it.
    func testMailArrivingAboveRenamesThePlace() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)
        XCTAssertEqual(place, try anchor(index: 30, uid: 970), "precondition")

        await world.scriptServer(size: 1002, stampsMessageIDs: true)
        await model.refresh()
        await world.settle(model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place?.index, 30)
        XCTAssertEqual(place?.uid, model.envelope(inSlot: 30)?.uid)
        XCTAssertNotEqual(place?.uid, 970, "the message two rows up is at the top now")
    }

    /// Mail arriving above a list a reader covers leaves the place naming
    /// its message: a fold from the reader lands the new list on that
    /// message, not on whatever took its row.
    func testACoveredListKeepsThePlacesMessage() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)
        tracker.disappeared()

        await world.scriptServer(size: 1002, stampsMessageIDs: true)
        await model.refresh()
        await world.settle(model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
    }

    // MARK: The landing's own move

    /// The landing's scroll can stop short of its row (the last rows of a
    /// folder cannot reach the top). Where it stopped is not recorded, or
    /// each fold would move the place a little; the next move is.
    func testTheLandingsOwnMoveIsNotRecorded() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        XCTAssertEqual(tracker.scrollRequest?.row, 200, "precondition")

        tracker.scrolled(toRow: 188, model: model)
        XCTAssertEqual(place, try anchor(index: 200, uid: 800))

        tracker.scrolled(toRow: 150, model: model)
        XCTAssertEqual(place, try anchor(index: 150, uid: 850))
    }

    /// A compact landing with a message to open pushes the reader in the
    /// same update, so the list may never run the scroll: when the list
    /// comes back it is asked again. Once the list has moved, it is not.
    func testARequestTheListNeverRanIsAskedAgainWhenItReturns() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        let first = try XCTUnwrap(tracker.scrollRequest)

        tracker.disappeared()
        tracker.appeared(model, in: navigator)
        let again = try XCTUnwrap(tracker.scrollRequest)
        XCTAssertEqual(again.row, 200)
        XCTAssertNotEqual(again, first, "asked again")

        tracker.scrolled(toRow: 200, model: model)
        tracker.disappeared()
        tracker.appeared(model, in: navigator)
        XCTAssertEqual(tracker.scrollRequest, again, "it ran; nothing more to ask")
    }

    /// The scroll goes to the row's slot as it is when the list scrolls: a
    /// row a full swipe replaced since the request has a new identity, and
    /// the one it had is no longer in the list.
    func testTheScrollGoesToTheRowsSlotAsItIsThen() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        let request = try XCTUnwrap(tracker.scrollRequest)
        XCTAssertEqual(request.slot(in: model), MessageListSlot(index: 200, generation: 0), "precondition")

        model.replaceRows(showing: [MessageRef](), alsoAt: [200])

        XCTAssertEqual(request.slot(in: model), MessageListSlot(index: 200, generation: 1))
    }

    // MARK: Claims

    /// A layout swap builds the new tree while this list is still being torn
    /// down: its scroll view collapsing to the top must not wipe the place.
    func testAListFromATornDownTreeRecordsNothing() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)

        navigator.listHold.handOff(isWide: true, folderPath: ListPagingWorld.folderPath, parkingIn: navigator.restores)
        tracker.scrolled(toRow: 0, model: model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(place, try anchor(index: 30, uid: 970))
        XCTAssertEqual(navigator.restores.pendingListAnchor, try anchor(index: 30, uid: 970))
    }

    /// A landing still waiting for its folder's count when a swap takes the
    /// window: the count arriving moves and loads nothing in the stale list.
    func testAStaleListsWaitingLandingDoesNothing() async throws {
        await world.imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let rows = ListPagingWorld.serverFolder(size: 1000, stampsMessageIDs: true)
        let model = try world.makeModel(preloaded: Array(rows.prefix(50)))
        await model.refresh()
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
        navigator.listHold.handOff(isWide: true, folderPath: ListPagingWorld.folderPath, parkingIn: navigator.restores)

        await world.scriptServer(size: 1000, stampsMessageIDs: true)
        await model.refresh()
        let before = await world.pages().count
        tracker.loadsChanged(model: model)
        await world.settle(model)

        XCTAssertNil(tracker.scrollRequest)
        let pages = await world.pages()
        XCTAssertEqual(pages.count, before, "no page for a list being torn down")
        XCTAssertEqual(navigator.restores.pendingListAnchor, try anchor(index: 400, uid: 600), "for the new list")
    }

    /// A list that stays alive through a back-out (its claim void) takes a
    /// new claim when it comes back on screen, and records again.
    func testAListThatSurvivesABackOutRecordsAgainWhenItReturns() async throws {
        let model = try await landedList()
        tracker.scrolled(toRow: 30, model: model)
        tracker.disappeared()
        navigator.listHold.backOut(from: navigator.restores)

        tracker.appeared(model, in: navigator)
        tracker.scrolled(toRow: 45, model: model)

        XCTAssertEqual(place, try anchor(index: 45, uid: 955))
    }

    /// The search surface has no folder and no index-addressed rows.
    func testTheSearchSurfaceIsInert() async throws {
        let folderModel = try await world.openedList(preloaded: 50, stampsMessageIDs: true)
        let search = MessageListViewModel(
            scope: .search, client: folderModel.client, preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: AppState().mailStore
        )

        tracker.appeared(search, in: navigator)
        tracker.land(model: search, in: navigator)
        tracker.scrolled(toRow: 3, model: search)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertNil(place)
    }
}
