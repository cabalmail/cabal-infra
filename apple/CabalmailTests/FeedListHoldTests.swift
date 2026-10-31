import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The split's feed list moving below a laptop fold and back
/// (`FeedListHold`): the next list for the same scope takes the moved one's
/// model and top row, once; another scope starts afresh; and the outgoing
/// list's teardown records nothing.
@MainActor
final class FeedListHoldTests: XCTestCase {
    private let scope = RssItemScope.subscription("s")

    private func model() throws -> FeedItemListViewModel {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return FeedItemListViewModel(scope: scope, subscription: nil, client: client,
                                     preferences: Preferences(store: InMemoryPreferenceStore()))
    }

    func testAMountWithNoMoveGetsNothing() throws {
        let hold = FeedListHold()
        let first = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, under: first.claim)

        XCTAssertNil(hold.mount(scope: scope).handoff)
    }

    func testAfterAMoveTheNextListTakesTheModelAndTopOnce() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        let held = try model()
        hold.register(held, scope: scope, under: column.claim)
        hold.record(topItemID: "item-40", under: column.claim)

        hold.move()
        let panel = hold.mount(scope: scope)

        let handoff = try XCTUnwrap(panel.handoff)
        XCTAssertTrue(handoff.model === held)
        XCTAssertEqual(handoff.topItemID, "item-40")
        XCTAssertNil(hold.mount(scope: scope).handoff, "handed to one list")
    }

    /// The column's list going away reports its rows leaving: none of that
    /// moves the place the panel's list lands on.
    func testTheOutgoingListRecordsNothingAfterTheMove() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, under: column.claim)
        hold.record(topItemID: "item-40", under: column.claim)

        hold.move()
        hold.record(topItemID: nil, under: column.claim)

        XCTAssertEqual(hold.mount(scope: scope).handoff?.topItemID, "item-40")
    }

    func testAListForAnotherScopeStartsAfreshAndDropsTheHeldOne() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, under: column.claim)

        hold.move()
        XCTAssertNil(hold.mount(scope: .all).handoff)

        hold.move()
        XCTAssertNil(hold.mount(scope: scope).handoff, "the held list went with the scope change")
    }

    /// The address list took the moved list's place in the laptop panel,
    /// and the window went to another list before the feed list came back:
    /// the same scope picked later starts afresh.
    func testAHandOffNoListTookIsReleased() throws {
        let hold = FeedListHold()
        let panel = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, under: panel.claim)
        hold.move()

        hold.releaseUntakenHandOff()

        XCTAssertNil(hold.mount(scope: scope).handoff)
    }

    /// Released after the next list has taken the hand-off, it leaves that
    /// list's claim and model alone.
    func testReleasingATakenHandOffChangesNothing() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        let held = try model()
        hold.register(held, scope: scope, under: column.claim)
        hold.move()
        let panel = hold.mount(scope: scope)
        hold.register(held, scope: scope, under: panel.claim)

        hold.releaseUntakenHandOff()
        XCTAssertTrue(hold.holds(panel.claim))
        hold.record(topItemID: "item-7", under: panel.claim)
        hold.move()

        let next = try XCTUnwrap(hold.mount(scope: scope).handoff)
        XCTAssertTrue(next.model === held)
        XCTAssertEqual(next.topItemID, "item-7")
    }

    func testTheNewListTakesTheClaim() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.move()
        let panel = hold.mount(scope: scope)

        XCTAssertFalse(hold.holds(column.claim))
        XCTAssertTrue(hold.holds(panel.claim))
    }

    /// A list for the same scope mounting afresh (a search ended, the task
    /// run again) drops what was held, so a move before it registers hands
    /// nothing stale over.
    func testAFreshMountOfTheSameScopeDropsTheHeldList() throws {
        let hold = FeedListHold()
        let first = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, under: first.claim)

        _ = hold.mount(scope: scope)
        hold.move()

        XCTAssertNil(hold.mount(scope: scope).handoff)
    }

    /// The list that took a moved one over keeps its top row across a
    /// second move, until the user scrolls it.
    func testATakenOverListKeepsItsTopAcrossASecondMove() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        let held = try model()
        hold.register(held, scope: scope, under: column.claim)
        hold.record(topItemID: "item-9", under: column.claim)

        hold.move()
        let panel = hold.mount(scope: scope)
        hold.register(held, scope: scope, under: panel.claim)

        hold.move()
        let back = try XCTUnwrap(hold.mount(scope: scope).handoff)
        XCTAssertTrue(back.model === held)
        XCTAssertEqual(back.topItemID, "item-9")
    }
}
