import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The window re-read (`WindowReconciler.rereadWindow`) reads positions the
/// list's rows were judged against; a reset that replaces those rows while
/// the read is out leaves it reading a window that no longer exists, so it
/// stands down on the generation rather than installing what it found
/// (#1870, #1981).
///
/// The reset here is a hard reload, which keeps the sort: the guard's
/// `sort == window.sortCriterion` clause therefore cannot be what drops the
/// read, and the generation is the only thing standing it down.
@MainActor
final class MessageListRereadStandDownTests: XCTestCase {
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

    func testAResetWhileTheRereadIsOutLeavesTheResetsTopPage() async throws {
        let (model, refresh) = try await world.refreshWaitingOnAPage()
        let loadedBefore = model.envelopes.count
        XCTAssertGreaterThan(loadedBefore, 50, "precondition: more than a top page is showing")

        // The re-read waits for the page in flight and then reads positions
        // itself: arm the next page request before letting that one answer,
        // and the read the re-read makes is what parks.
        await world.imap.holdNext(.envelopes)
        await world.imap.releaseHeld(.envelopes)
        await world.imap.awaitHeld(.envelopes)

        await model.hardReload()
        XCTAssertEqual(model.envelopes.count, 50, "the reset's own top page")

        await world.imap.releaseHeld(.envelopes)
        await refresh.value
        await world.settle(model)

        XCTAssertEqual(model.envelopes.count, 50, "the re-read's window was not installed over the reset's")
        XCTAssertEqual(model.window!.windowStart, 0)
        XCTAssertFalse(model.isLoading)
    }
}
