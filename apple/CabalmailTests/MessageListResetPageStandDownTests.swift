import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A page above the window, or a jump's window, still out when a sort pick
/// resets the rows it was addressed to lands nowhere (#1870). The page
/// below has the same pin (`MessageListResetStandDownTests`).
///
/// A search used to pin these two as well, while its results shared the
/// folder window's rows. Since 2.2 C a search's rows live in its
/// `MailSearchSession`, so a page that lands under a search can no longer
/// reach the rows on screen, and what stands it down is pinned here, on a
/// folder list's reset, where it still could.
///
/// The fake answers a held page even when its task was cancelled meanwhile
/// (`answerEnvelopesAfterCancellation()`), so what drops it is the
/// generation, not the cancel.
@MainActor
final class MessageListResetPageStandDownTests: XCTestCase {
    private var world: ListPagingWorld!
    private let subjectOrder = SortCriterion(field: .subject, direction: .ascending)

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

    func testASortChangeDropsAPageAboveStillOutInTheOldOrder() async throws {
        let model = try await world.openedList(preloaded: 600)
        model.window!.ensureLoaded(around: 599)
        await world.settle(model)
        XCTAssertEqual(model.window!.windowStart, 200, "precondition: the window starts below the top")
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.window!.ensureLoaded(around: 200)
        XCTAssertTrue(model.window!.isLoadingPrevious)
        await world.imap.awaitHeld(.envelopes)

        await model.window!.setSort(subjectOrder)
        XCTAssertEqual(model.window!.loadPrevTask?.isCancelled, true, "the reset stood the page down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        XCTAssertEqual(model.window!.windowStart, 0)
        XCTAssertEqual(model.envelopes.count, 50, "the new order's top page alone")
        XCTAssertEqual(Set(model.envelopes.map(\.uid)), Set(ListPagingWorld.uids(0..<50)))
    }

    func testASortChangeDropsAJumpStillOutInTheOldOrder() async throws {
        let model = try await world.openedList()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.window!.ensureLoaded(around: 900)
        XCTAssertTrue(model.window!.isLoadingWindow)
        await world.imap.awaitHeld(.envelopes)

        await model.window!.setSort(subjectOrder)
        XCTAssertEqual(model.window!.loadWindowTask?.isCancelled, true, "the reset stood the jump down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        XCTAssertEqual(model.window!.windowStart, 0)
        XCTAssertEqual(model.envelopes.count, 50, "the new order's top page alone")
        XCTAssertEqual(Set(model.envelopes.map(\.uid)), Set(ListPagingWorld.uids(0..<50)))
    }
}
