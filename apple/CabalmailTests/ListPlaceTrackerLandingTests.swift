import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder list landing on the place its window parked or kept
/// (`ListPlaceTracker`), over the scripted folder of `ListPagingWorld`
/// (index `i` of an `n`-message folder holds UID `n - i`, stamped with that
/// UID's Message-ID). The tracker is driven as its view modifier drives it:
/// `appeared`, `land`, `scrolled`, `loadsChanged`. What it asks the list to
/// scroll to is `scrollRequest`, and the window's place is the hold's.
@MainActor
final class ListPlaceTrackerLandingTests: XCTestCase {
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

    /// The place a list showing UID `uid` at its top, at row `index`, records.
    private func anchor(index: Int, uid: UInt32) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: ListPagingWorld.folderPath, messageID: ListPagingWorld.messageID(uid), uid: uid, index: index
        ))
    }

    private var place: ListAnchor? { navigator.listHold.place }

    private func appearAndLand(_ model: MessageListViewModel) {
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)
    }

    // MARK: Found among the loaded rows

    func testALandWithNothingParkedLeavesThePlaceAndDoesNotScroll() async throws {
        let model = try await world.openedList(stampsMessageIDs: true)

        appearAndLand(model)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertNil(place)
    }

    /// Three messages arrived since the place was recorded: the message is
    /// three rows further down, and the list opens on it, not on its old row.
    func testALandScrollsToTheParkedMessagesRow() async throws {
        let model = try await world.openedList(size: 1003, preloaded: 250, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))

        appearAndLand(model)

        XCTAssertEqual(tracker.scrollRequest?.row, 103)
        XCTAssertEqual(place, try anchor(index: 103, uid: 900))
        XCTAssertNil(navigator.restores.pendingListAnchor, "taken")
    }

    // MARK: Not loaded yet

    /// A far place: the list scrolls to the row the place had, loads one
    /// page around it, and corrects once for the mail that arrived since.
    func testAFarAnchorLoadsOnePageCentredOnItAndCorrectsOnce() async throws {
        let model = try await world.openedList(size: 1003, stampsMessageIDs: true)
        XCTAssertNil(model.envelope(inSlot: 400), "precondition: only the top page is loaded")
        let before = await world.pages().count
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))

        appearAndLand(model)

        let guess = try XCTUnwrap(tracker.scrollRequest)
        XCTAssertEqual(guess.row, 400)
        XCTAssertEqual(place, try anchor(index: 400, uid: 600), "the parked identity, at the guessed row")
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages.count, before + 1, "one page: \(pages.suffix(2))")
        XCTAssertEqual(model.envelope(inSlot: 403)?.uid, 600, "it holds the message's row")

        tracker.scrolled(toRow: 400, model: model)
        tracker.loadsChanged(model: model)

        let corrected = try XCTUnwrap(tracker.scrollRequest)
        XCTAssertEqual(corrected.row, 403)
        XCTAssertNotEqual(corrected, guess)
        XCTAssertEqual(place, try anchor(index: 403, uid: 600))

        tracker.scrolled(toRow: 403, model: model)
        tracker.loadsChanged(model: model)
        XCTAssertEqual(tracker.scrollRequest, corrected, "corrected once")
    }

    /// A place within reach of the loaded rows comes in by the list's
    /// ordinary paging, a page at a time, with no jump: the landing asks
    /// again until its row is there.
    func testANearTargetConvergesOverTwoPages() async throws {
        let model = try await world.openedList(stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 280, uid: 720))

        appearAndLand(model)
        let request = try XCTUnwrap(tracker.scrollRequest)
        XCTAssertEqual(request.row, 280)
        tracker.scrolled(toRow: 280, model: model)
        for _ in 0..<3 where model.envelope(inSlot: 280) == nil {
            await world.settle(model)
            tracker.loadsChanged(model: model)
        }
        await world.settle(model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(model.envelope(inSlot: 280)?.uid, 720)
        XCTAssertEqual(place, try anchor(index: 280, uid: 720))
        XCTAssertEqual(tracker.scrollRequest, request, "it was already on its row")
    }

    /// A guess never overwrites: while the row is still on its way, a move
    /// of the list updates the place's index and keeps the parked identity.
    func testWhileTheRowIsOnItsWayTheIdentityStays() async throws {
        let model = try await world.openedList(size: 1003, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))
        await world.imap.holdNext(.envelopes)
        appearAndLand(model)
        await world.imap.awaitHeld(.envelopes)
        tracker.scrolled(toRow: 400, model: model)

        tracker.scrolled(toRow: 396, model: model)

        XCTAssertEqual(place, try anchor(index: 396, uid: 600))
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)
    }

    /// The user scrolls away while the row is on its way: that wins. The
    /// list is not pulled back, and the place is the row it is on.
    func testTheUsersScrollWinsOverTheCorrection() async throws {
        let model = try await world.openedList(size: 1003, stampsMessageIDs: true)
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))
        await world.imap.holdNext(.envelopes)
        appearAndLand(model)
        await world.imap.awaitHeld(.envelopes)
        let guess = try XCTUnwrap(tracker.scrollRequest)
        tracker.scrolled(toRow: 400, model: model)

        tracker.userScrolled()
        tracker.scrolled(toRow: 20, model: model)
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)
        tracker.loadsChanged(model: model)

        XCTAssertEqual(tracker.scrollRequest, guess, "no correction")
        XCTAssertEqual(place?.index, 20)

        // The rows the user scrolled to ask for their own page, as the
        // list's rows do, and the place names the message there.
        model.window?.ensureLoaded(around: 20)
        await world.settle(model)
        tracker.loadsChanged(model: model)
        XCTAssertEqual(tracker.scrollRequest, guess)
        XCTAssertEqual(place, try anchor(index: 20, uid: 983))
    }

    // MARK: Offline, and an empty folder

    /// Offline the list is only as long as its loaded rows. A place past
    /// them is kept, not moved to the last row; when the folder's count
    /// arrives the landing goes ahead.
    func testOfflinePastTheLoadedRowsWaitsThenLandsWhenTheCountArrives() async throws {
        await world.imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let rows = ListPagingWorld.serverFolder(size: 1000, stampsMessageIDs: true)
        let model = try world.makeModel(preloaded: Array(rows.prefix(50)))
        await model.refresh()
        XCTAssertNotNil(model.errorMessage, "precondition: the refresh failed")
        navigator.restores.parkListAnchor(try anchor(index: 400, uid: 600))

        appearAndLand(model)
        tracker.scrolled(toRow: 0, model: model)

        XCTAssertNil(tracker.scrollRequest, "no scroll to the last loaded row")
        XCTAssertEqual(place, try anchor(index: 400, uid: 600), "the place is kept")

        await world.scriptServer(size: 1000, stampsMessageIDs: true)
        await model.refresh()
        XCTAssertNil(model.errorMessage, "precondition: back online")
        tracker.loadsChanged(model: model)

        XCTAssertEqual(tracker.scrollRequest?.row, 400)
        await world.settle(model)
    }

    func testAFolderWithNoRowsDropsThePlace() async throws {
        let model = try await world.openedList(size: 0, stampsMessageIDs: true)
        let earlier = navigator.listHold.claim(ListPagingWorld.folderPath)
        navigator.listHold.record(try anchor(index: 400, uid: 600), under: earlier)

        appearAndLand(model)

        XCTAssertNil(place)
        XCTAssertNil(tracker.scrollRequest)
    }

    // MARK: Lists that do not land

    /// A list on a pill takes the anchor parked for its folder, so it does
    /// not wait for a later list, but neither scrolls nor touches the place.
    func testAListOnAPillTakesTheAnchorWithoutScrolling() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        let earlier = navigator.listHold.claim(ListPagingWorld.folderPath)
        navigator.listHold.record(try anchor(index: 30, uid: 970), under: earlier)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))
        model.filterTab = .unread

        appearAndLand(model)
        tracker.scrolled(toRow: 5, model: model)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertEqual(place, try anchor(index: 30, uid: 970), "the place is left as it was")
    }

    /// A list lands once: back from a reader, it applies nothing, even with
    /// an anchor parked meanwhile.
    func testASecondLandDoesNothing() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        appearAndLand(model)
        navigator.restores.parkListAnchor(try anchor(index: 100, uid: 900))

        tracker.disappeared()
        tracker.appeared(model, in: navigator)
        tracker.land(model: model, in: navigator)

        XCTAssertNil(tracker.scrollRequest)
        XCTAssertNotNil(navigator.restores.pendingListAnchor, "left for the next list")
    }

    /// The same folder's list mounting again in the tree (back from a
    /// search) reopens at the window's place, with nothing parked.
    func testAListMountingAgainReusesTheWindowsPlace() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        appearAndLand(model)
        tracker.scrolled(toRow: 120, model: model)
        XCTAssertEqual(place, try anchor(index: 120, uid: 880), "precondition")

        let again = ListPlaceTracker()
        again.appeared(model, in: navigator)
        again.land(model: model, in: navigator)

        XCTAssertEqual(again.scrollRequest?.row, 120)
    }

    func testAListOutsideAWindowIsInert() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)

        tracker.appeared(model, in: nil)
        tracker.land(model: model, in: nil)
        tracker.scrolled(toRow: 30, model: model)
        tracker.loadsChanged(model: model)

        XCTAssertNil(tracker.scrollRequest)
    }
}
