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
        hold.register(try model(), scope: scope, title: "Feed", under: first.claim)

        XCTAssertNil(hold.mount(scope: scope).handoff)
    }

    func testAfterAMoveTheNextListTakesTheModelAndTopOnce() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        let held = try model()
        hold.register(held, scope: scope, title: "Rust Blog", under: column.claim)
        hold.record(topItemID: "item-40", under: column.claim)

        hold.move()
        let panel = hold.mount(scope: scope)

        let handoff = try XCTUnwrap(panel.handoff)
        XCTAssertTrue(handoff.model === held)
        XCTAssertEqual(handoff.title, "Rust Blog")
        XCTAssertEqual(handoff.topItemID, "item-40")
        XCTAssertNil(hold.mount(scope: scope).handoff, "handed to one list")
    }

    /// The column's list going away reports its rows leaving: none of that
    /// moves the place the panel's list lands on.
    func testTheOutgoingListRecordsNothingAfterTheMove() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, title: "Feed", under: column.claim)
        hold.record(topItemID: "item-40", under: column.claim)

        hold.move()
        hold.record(topItemID: nil, under: column.claim)

        XCTAssertEqual(hold.mount(scope: scope).handoff?.topItemID, "item-40")
    }

    func testAListForAnotherScopeStartsAfreshAndDropsTheHeldOne() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.register(try model(), scope: scope, title: "Feed", under: column.claim)

        hold.move()
        XCTAssertNil(hold.mount(scope: .all).handoff)

        hold.move()
        XCTAssertNil(hold.mount(scope: scope).handoff, "the held list went with the scope change")
    }

    func testTheNewListTakesTheClaim() throws {
        let hold = FeedListHold()
        let column = hold.mount(scope: scope)
        hold.move()
        let panel = hold.mount(scope: scope)

        XCTAssertFalse(hold.holds(column.claim))
        XCTAssertTrue(hold.holds(panel.claim))
    }
}
