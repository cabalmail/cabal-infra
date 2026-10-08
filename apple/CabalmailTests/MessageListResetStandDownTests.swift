import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder load still out when a reset replaces the rows it was addressed
/// to lands nowhere (#1870, #1820): the reset cancels it and moves the
/// window's generation, and the load drops its page when it lands anyway.
/// Searches stand loads down the same way
/// (`MessageListSearchStandDownTests`).
///
/// The fake answers a held page even when its task was cancelled meanwhile
/// (`answerEnvelopesAfterCancellation()`), so what drops it is the
/// generation, not the cancel.
@MainActor
final class MessageListResetStandDownTests: XCTestCase {
    private var world: ListPagingWorld!

    override func setUp() async throws {
        // A hold that is never reached would otherwise hang until the CI job
        // times out without naming the test.
        executionTimeAllowance = 60
        world = ListPagingWorld()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// A page out in the old order when the sort changes would put rows of
    /// that order into the new one's window.
    func testASortChangeDropsAPageStillOutInTheOldOrder() async throws {
        let model = try await world.openedList()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.window.ensureLoaded(around: 0)
        await world.imap.awaitHeld(.envelopes)

        await model.window.setSort(SortCriterion(field: .subject, direction: .ascending))
        XCTAssertEqual(model.window.loadMoreTask?.isCancelled, true, "the reset stood the page down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        XCTAssertEqual(model.envelopes.count, 50, "the new order's top page alone")
        let pages = await world.pages()
        XCTAssertEqual(pages.first?.sort, .default, "the page that was dropped")
    }

    /// A page out when the folder's UIDVALIDITY changes names messages of the
    /// mailbox as it was; its UIDs mean nothing in the one that replaced it.
    func testAUidValidityChangeDropsAPageStillOut() async throws {
        let model = try await world.openedList()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.window.ensureLoaded(around: 0)
        await world.imap.awaitHeld(.envelopes)

        await world.imap.scriptStatusResults([.success(FolderStatus(
            messages: 1000, unseen: 0, flagged: 0, uidValidity: 8, uidNext: 1001
        ))])
        await model.refresh()
        XCTAssertEqual(model.window.loadMoreTask?.isCancelled, true, "the reset stood the page down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        XCTAssertEqual(model.envelopes.count, 50, "the new mailbox's top page alone")
        XCTAssertEqual(model.window.uidValidity, 8)
    }

    // MARK: - A refresh waiting on a page

    /// A refresh whose re-read waits for a page already out
    /// (`ListPagingWorld.refreshWaitingOnAPage()`), overtaken by Refresh: the
    /// reset's pass rebuilds the list, and the pass that waited stands down
    /// rather than landing a second top page behind it (#1820).
    func testAResetWhileARefreshWaitsOnAPageLeavesOnlyTheResetsTopPage() async throws {
        let (model, refresh) = try await world.refreshWaitingOnAPage()
        let topsBefore = await world.imap.topEnvelopesCalls.count

        await model.hardReload()
        await world.imap.releaseHeld(.envelopes)
        await refresh.value
        await world.settle(model)

        let tops = await world.imap.topEnvelopesCalls.count
        XCTAssertEqual(tops, topsBefore + 1, "the reset's top page, and no second one")
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(0..<50, size: 999))
        XCTAssertFalse(model.isLoading)
    }
}
