import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a launch reads back about the window it left behind (#1836 item 1).
/// A window hydrated from the snapshot used to be anchored to nothing, so a
/// row removed while the folder was closed could only be proven gone by a
/// read that held the whole folder -- in anything larger it stayed on disk,
/// an offline launch showed it and a Spotlight hit opened it. The snapshot
/// now carries the anchor its rows were proven against, and these tests
/// cover what that buys and when it is refused. The world is shared with
/// `MessageListWindowReconcileTests` (`WindowReconcileWorld.swift`).
@MainActor
final class MessageListSavedWindowTests: XCTestCase {

    /// The gap this closes: a row removed while the folder was closed used
    /// to stay in the snapshot of any folder one read can't hold, because a
    /// hydrated window was anchored to nothing and so could prove nothing
    /// gone. With the record the first read covers the window's own rows and
    /// the row leaves the snapshot, Spotlight and the offline list.
    func testASavedWindowRecordLetsTheFirstReadOfALaunchProveARowGone() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        await world.persistWindow()
        try await world.client.bodyCache.store(folder: "INBOX", uidValidity: 7, uid: 500, bytes: Data("x".utf8))
        // Deleted elsewhere while the folder was closed.
        await world.server.remove(500)

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let pages = await world.server.pageCalls
        XCTAssertEqual(Array(pages.suffix(2)), [Page(offset: 0, limit: 250), Page(offset: 249, limit: 201)],
                       "the read covers the saved window, not just its first page")
        XCTAssertFalse(reopened.envelopes.contains { $0.uid == 500 })
        try await world.assertAligned(reopened)
        let cached = try await world.snapshotUIDs()
        XCTAssertFalse(cached.contains(500), "the row the anchor let the read prove gone leaves the snapshot")
        let body = await world.client.bodyCache.fetch(folder: "INBOX", uidValidity: 7, uid: 500)
        XCTAssertNil(body)

        // And an offline launch after that one doesn't show it either.
        await world.server.setOffline(true)
        let offline = world.makeModel()
        await offline.loadInitial()
        XCTAssertFalse(offline.envelopes.contains { $0.uid == 500 })
    }

    /// A record that no longer names the rows on disk proves nothing about
    /// them: the launch falls back to the one-page read of a window anchored
    /// to nothing, which leaves the uncovered row on disk.
    func testARecordTheSnapshotsRowsHaveMovedOnFromIsIgnored() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        await world.persistWindow()
        try await world.rewriteWindowRecord {
            EnvelopeCache.WindowRecord(total: $0.total, uidNext: $0.uidNext, sort: $0.sort, uids: $0.uids + [9_999])
        }
        await world.server.remove(500)

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250), "the unanchored read of one page")
        let cached = try await world.snapshotUIDs()
        XCTAssertTrue(cached.contains(500), "nothing proved the row gone")
        try await world.assertAligned(reopened)
    }

    /// Positions are per-order, so a record read back under another sort
    /// says nothing about where these rows sit.
    func testARecordWrittenUnderAnotherSortIsIgnored() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        await world.persistWindow()
        try await world.rewriteWindowRecord {
            EnvelopeCache.WindowRecord(
                total: $0.total, uidNext: $0.uidNext,
                sort: SortCriterion(field: .subject, direction: .ascending), uids: $0.uids
            )
        }
        await world.server.remove(500)

        let reopened = world.makeModel()
        await reopened.loadInitial()

        let pages = await world.server.pageCalls
        XCTAssertEqual(pages.last, Page(offset: 0, limit: 250), "the unanchored read of one page")
        let cached = try await world.snapshotUIDs()
        XCTAssertTrue(cached.contains(500))
    }

    /// A refresh saves the window it settled on, so the record is there for
    /// the next launch without waiting for a page to be scrolled.
    func testARefreshSavesTheWindowRecordItSettledOn() async throws {
        let world = try await World.opened(size: 600, pages: 2)
        let before = await world.savedWindowRecord()
        XCTAssertNil(before, "nothing has written a record yet")

        await world.model.refresh()
        await world.model.window!.persistTask?.value

        let saved = await world.savedWindowRecord()
        let record = try XCTUnwrap(saved)
        XCTAssertEqual(record.total, 600)
        XCTAssertEqual(record.uidNext, 601)
        XCTAssertEqual(record.sort, .default)
        XCTAssertEqual(Set(record.uids), Set(world.model.envelopes.map(\.uid)))
    }
}
