import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The loaded window has to stay lined up with the server's positions when
/// the folder changes elsewhere (#1817, #1818). Each test drives a real
/// `MessageListViewModel` against `ServerFolder`, a folder that answers
/// STATUS and positional pages from one list of UIDs, so the assertion is
/// always the same: every loaded index holds the UID the server has there.
@MainActor
final class MessageListWindowReconcileTests: XCTestCase {

    // MARK: - #1817: a removal made elsewhere under a paginated window

    func testARemovalElsewhereLeavesAPaginatedWindowAndTheNextPageSkipsNothing() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        XCTAssertEqual(world.model.envelopes.count, 250)
        let topsBefore = await world.server.topCalls.count
        await world.server.remove(330)

        await world.model.refresh()

        let pages = await world.server.pageCalls
        let tops = await world.server.topCalls.count
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250), "one read of the window's reach")
        XCTAssertEqual(tops, topsBefore, "which stands in for the top page")
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()

        world.model.window!.ensureLoaded(around: 249)
        await world.model.window!.loadMoreTask?.value
        XCTAssertEqual(world.model.envelopes.count, 399, "the next page loads the rest of the folder")
        try await world.assertAligned()
        XCTAssertTrue(world.model.envelopes.contains { $0.uid == 150 }, "the row at the old page boundary is loaded")
    }

    func testARowRemovedElsewhereLeavesBothCachesAndStaysGoneOnTheNextOpen() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.persistSnapshot()
        try await world.client.bodyCache.store(folder: "INBOX", uidValidity: 7, uid: 330, bytes: Data("x".utf8))
        let before = try await world.snapshotUIDs()
        XCTAssertTrue(before.contains(330), "the row starts out on disk")
        await world.server.remove(330)

        await world.model.refresh()

        let after = try await world.snapshotUIDs()
        XCTAssertFalse(after.contains(330))
        let body = await world.client.bodyCache.fetch(folder: "INBOX", uidValidity: 7, uid: 330)
        XCTAssertNil(body)

        // Reopened offline: the snapshot is all there is, and the row is
        // not in it.
        await world.server.setOffline(true)
        let reopened = world.makeModel()
        await reopened.loadInitial()
        XCTAssertEqual(reopened.envelopes.count, 250, "the read's rows, which replaced 330 with 150")
        XCTAssertFalse(reopened.envelopes.contains { $0.uid == 330 })
    }

    func testAWindowWiderThanOnePageIsReadAcrossPagesAndProvesTheRowGone() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        XCTAssertEqual(world.model.envelopes.count, 450)
        await world.persistSnapshot()
        await world.server.remove(500)

        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(Array(pages.suffix(2)), [Page(offset: 0, limit: 250), Page(offset: 249, limit: 201)],
                       "two pages sharing one row at the seam")
        try await world.assertAligned()
        let cached = try await world.snapshotUIDs()
        XCTAssertFalse(cached.contains(500))
    }

    // MARK: - #1836: a `\Deleted` flag set elsewhere, with no expunge

    /// A message flagged `\Deleted` elsewhere leaves the `NOT DELETED` sort
    /// the pages are served from while STATUS MESSAGES still counts it, so a
    /// window anchored on MESSAGES sees no change and sits a row off from
    /// there down. The anchor reads the not-deleted count instead (#1836).
    func testAMessageFlaggedDeletedElsewhereLeavesAPaginatedWindow() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        XCTAssertEqual(world.model.envelopes.count, 450)
        await world.persistSnapshot()
        await world.server.flagDeleted(500)

        await world.model.refresh()

        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 500 })
        XCTAssertEqual(world.model.window!.totalMessages, 599, "the count the positions are in")
        try await world.assertAligned()
        let cached = try await world.snapshotUIDs()
        XCTAssertFalse(cached.contains(500), "and the row the read proved gone leaves the snapshot")
    }

    func testAFolderEmptiedElsewhereEmptiesAPaginatedWindow() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.removeAll()

        await world.model.refresh()

        XCTAssertTrue(world.model.envelopes.isEmpty)
        XCTAssertEqual(world.model.window!.totalMessages, 0)
    }

    // MARK: - The common cases cost nothing extra

    func testNewMailOnTopOfAPaginatedWindowTakesOnlyTheTopPage() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        await world.server.arrive(3)

        await world.model.refresh()
        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore, "no positional read for mail that lands in the top page")
        XCTAssertEqual(world.model.envelopes.count, 253)
        try await world.assertAligned()
    }

    func testThisListsOwnMoveIsNotReadAsAChangeElsewhere() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        let row = try XCTUnwrap(world.model.envelopes.first { $0.uid == 300 })

        await world.model.moveTo(row, destination: "Archive")
        await world.model.refresh()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore)
        XCTAssertEqual(world.model.envelopes.count, 249)
        try await world.assertAligned()
    }

    // MARK: - When a re-read waits or gives up

    func testARefreshThatMayPredateARemovalLeavesTheWindowForTheNextOne() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        await world.server.remove(330)
        world.model.mailStore.shields.beginRemoval([MessageRef(folder: "INBOX", uid: 399)])

        await world.model.refresh()
        let pagesDuring = await world.server.pageCalls.count
        XCTAssertEqual(pagesDuring, pagesBefore, "a reply that may count a removal in flight proves nothing")

        world.model.mailStore.shields.endRemoval([MessageRef(folder: "INBOX", uid: 399)])
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    func testARemovalThatStartsWhileTheReadIsOutAbandonsIt() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.remove(330)
        await world.server.holdNext(.page)

        let refresh = Task { await world.model.refresh() }
        await world.server.awaitHeld(.page)
        world.model.mailStore.shields.beginRemoval([MessageRef(folder: "INBOX", uid: 399)])
        await world.server.release(.page)
        await refresh.value

        XCTAssertTrue(world.model.envelopes.contains { $0.uid == 330 }, "the read was dropped, not installed")
        world.model.mailStore.shields.endRemoval([MessageRef(folder: "INBOX", uid: 399)])
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    func testABulkSelectionHoldsTheReadUntilItIsCleared() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        let pagesBefore = await world.server.pageCalls.count
        world.model.bulkMode = true
        world.model.selectedRefs = [MessageRef(folder: "INBOX", uid: 380)]
        await world.server.remove(330)

        await world.model.refresh()
        let pagesDuring = await world.server.pageCalls.count
        XCTAssertEqual(pagesDuring, pagesBefore, "rows don't move under a selection being built")

        world.model.selectedRefs = []
        await world.model.refresh()
        XCTAssertFalse(world.model.envelopes.contains { $0.uid == 330 })
        try await world.assertAligned()
    }

    /// A refresh asked for while a quiet one is out waits for it (#1820),
    /// so the quiet pass's top page lands on the window it was asked for,
    /// never on one a re-read has since moved deep. The rerun then sees the
    /// change and reads the window again, centred on the viewport.
    func testARefreshAskedForWhileOneIsOutRealignsTheWindowOnceThatOneLands() async throws {
        let world = try await World.opened(size: 1000, pages: 2)
        world.model.window!.visibleRowIndices = [380: 1, 420: 1]
        await world.server.holdNext(.top)
        let quiet = Task { await world.model.refresh() }
        await world.server.awaitHeld(.top)

        // Enough arrivals that the rows' reach passes the window cap, so the
        // re-read centres on the viewport, plus a removal to trigger it.
        await world.server.arrive(200)
        await world.server.remove(900)
        let rerun = Task { await world.model.refresh() }
        try await waitUntilOnMainActor { world.model.window!.refreshFlight.waiting == 1 }
        XCTAssertFalse(world.model.window!.hasTrimmedFront, "nothing moves the window while the quiet pass is out")

        await world.server.release(.top)
        await quiet.value
        await rerun.value
        XCTAssertTrue(world.model.window!.hasTrimmedFront)
        try await world.assertAligned()
    }

    func testAFailedReadFromTheTopIsReportedAndADeepOneIsNot() async throws {
        let top = try await World.opened(size: 400, pages: 1)
        await top.server.remove(330)
        await top.server.setPagesFail(true)
        await top.model.refresh()
        XCTAssertNotNil(top.model.errorMessage)

        let deep = try await World.opened(size: 600, jumpTo: 500)
        await deep.server.arrive(1)
        await deep.server.setPagesFail(true)
        await deep.model.refresh()
        XCTAssertNil(deep.model.errorMessage)
    }

    // MARK: - #1818: changes above a trimmed window

    func testNewMailAboveATrimmedWindowRealignsItAndScrollingUpSkipsNothing() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        XCTAssertTrue(world.model.window!.hasTrimmedFront)
        await world.server.arrive(1)

        await world.model.refresh()
        try await world.assertAligned()

        let loaded = world.model.envelopes.count
        world.model.window!.ensureLoaded(around: Int(world.model.window!.windowStart))
        await world.model.window!.loadPrevTask?.value
        XCTAssertGreaterThan(world.model.envelopes.count, loaded, "scrolling up loads the page above")
        try await world.assertAligned()
    }

    func testARemovalAboveATrimmedWindowRealignsIt() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        await world.server.remove(500)

        await world.model.refresh()
        try await world.assertAligned()

        let loaded = world.model.envelopes.count
        world.model.window!.ensureLoaded(around: Int(world.model.window!.windowStart))
        await world.model.window!.loadPrevTask?.value
        XCTAssertGreaterThan(world.model.envelopes.count, loaded)
        try await world.assertAligned()
    }

    func testAQuietRefreshOfATrimmedWindowReadsNothing() async throws {
        let world = try await World.opened(size: 600, jumpTo: 500)
        let pagesBefore = await world.server.pageCalls.count

        await world.model.refresh()

        let pages = await world.server.pageCalls
        let tops = await world.server.topCalls
        XCTAssertEqual(pages.count, pagesBefore)
        XCTAssertEqual(tops.count, 1, "only the open's top page")
    }

    // MARK: - Arrivals the top page doesn't hold

    func testMailMovedInBelowTheTopPageRealignsThePaginatedWindow() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.server.arrive(at: 120)

        await world.model.refresh()

        try await world.assertAligned()
        let arrived = await world.server.uids[120]
        XCTAssertTrue(world.model.envelopes.contains { $0.uid == arrived })
    }

    // MARK: - Opening from the snapshot

    func testAnOfflineOpenShowsTheWholeSnapshot() async throws {
        let world = try await World.opened(size: 400, pages: 1)
        await world.persistSnapshot()
        await world.server.setOffline(true)
        let pagesBefore = await world.server.pageCalls.count

        let reopened = world.makeModel()
        await reopened.loadInitial()

        XCTAssertEqual(reopened.envelopes.count, 250)
        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.count, pagesBefore)
    }

    func testAnOnlineOpenReadsTheSnapshotWindowAgainAndKeepsWhatItDidntCover() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        await world.persistSnapshot()
        // Deleted while the folder was closed.
        await world.server.remove(500)

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250))
        XCTAssertFalse(reopened.envelopes.contains { $0.uid == 500 })
        try await world.assertAligned(reopened)
        // Nothing proves where the rows past the read went, so they stay
        // on disk for the next offline open.
        let cached = try await world.snapshotUIDs()
        XCTAssertTrue(cached.contains(200), "a row the read didn't cover is kept")
        XCTAssertEqual(cached.count, 450)
    }

    func testAnOpenThatReadsTheWholeFolderClearsRowsGoneSinceTheLastSession() async throws {
        let world = try await World.opened(size: 120, pages: 1)
        await world.persistSnapshot()
        for uid: UInt32 in [100, 90, 80] { await world.server.remove(uid) }

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let cached = try await world.snapshotUIDs()
        let server = await world.server.uids
        XCTAssertEqual(cached, Set(server))
        try await world.assertAligned(reopened)
    }
}
