import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The feed reader's transitions (`FeedNavigationState`), which both feed
/// trees share: the wide split and the Feeds tab. Before, each tree kept its
/// own copy as view state and they disagreed on when a restored item opens.
final class FeedNavigationStateTests: XCTestCase {
    private let tree = UUID()
    private let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")
    private let other = RssItem(feedId: "f", subscriptionId: "s", itemId: "j", sortKey: "l")

    /// A state whose reader belongs to `tree`, with `item` open in `scope`.
    private func reading(_ scope: RssItemScope = .all) -> FeedNavigationState {
        var state = FeedNavigationState()
        _ = state.appear(tree)
        state.mount(tree)
        _ = state.selectScope(scope)
        _ = state.selectItem(item, from: tree)
        return state
    }

    /// #1664, on every layout: picking a scope never selects an item in the
    /// same transition, so a list and its reader are never pushed in one
    /// update. The item parked for the scope is left for the list, which
    /// applies it once it has appeared and loaded (`FeedItemListView`). This
    /// replaces the source scan that checked `FeedRootView`'s scope handler
    /// never consumed the restore.
    func testPickingAScopeNeverSelectsAnItemInTheSameTransition() {
        var state = reading(.subscription("a"))

        let records = state.selectScope(.subscription("b"))

        XCTAssertEqual(records, [.scope(.subscription("b"))])
        XCTAssertNil(state.item)
        XCTAssertEqual(state.column, .content, "the list, not the reader")
    }

    func testPickingTheScopeOnScreenChangesNothing() {
        var state = reading()

        XCTAssertEqual(state.selectScope(.all), [])
        XCTAssertEqual(state.item, item)
    }

    /// The wide split showing mail holds the compact Feeds tab's place; a
    /// pick there opens the scope afresh even when it is the one held.
    func testOpeningTheHeldScopeStartsItAfresh() {
        var state = reading()

        XCTAssertEqual(state.openScope(.all), [.scope(.all)])
        XCTAssertNil(state.item)
        XCTAssertEqual(state.column, .content)
    }

    func testClearingTheScopeShowsTheFeedList() {
        var state = reading()

        XCTAssertEqual(state.selectScope(nil), [.scope(nil)])
        XCTAssertEqual(state.column, .sidebar)
    }

    func testAnItemPushesTheReaderAndIsRecorded() {
        var state = reading()

        XCTAssertEqual(state.selectItem(other, from: tree), [.item(other)])
        XCTAssertEqual(state.column, .detail)
        XCTAssertEqual(state.selectItem(other, from: tree), [], "the same item again records nothing")
    }

    /// Backing out of the reader drops the item, so the same row can be
    /// opened again; that is recorded, as the old column handler's item
    /// change was.
    func testLeavingTheReaderDropsTheItem() {
        var state = reading()

        XCTAssertEqual(state.setColumn(.content, from: tree), [.item(nil)])
        XCTAssertNil(state.item)
        XCTAssertEqual(state.setColumn(.sidebar, from: tree), [], "no item left to drop")
    }

    /// Until a tree has taken over it sees nothing, and only the tree that
    /// owns the reader, with nothing appeared since, can change it.
    func testOnlyTheMountedTreeSeesAndWrites() {
        var state = reading()
        let rebuilt = UUID()

        XCTAssertTrue(state.appear(rebuilt), "a second tree is a rebuild")
        XCTAssertNil(state.scope(in: rebuilt))
        XCTAssertEqual(state.column(in: rebuilt), .sidebar)
        XCTAssertEqual(state.selectItem(other, from: tree), [], "the replaced tree can't write")
        XCTAssertEqual(state.selectItem(other, from: rebuilt), [], "nor can the new one before it takes over")

        state.mount(rebuilt)
        XCTAssertEqual(state.scope(in: rebuilt), .all)
        XCTAssertNil(state.scope(in: tree))
        XCTAssertEqual(state.selectItem(other, from: rebuilt), [.item(other)])
    }

    /// A tree a swap built takes the item to park for its list, and the
    /// column starts on that list. Nothing is recorded: the window is where
    /// it was.
    func testAHandOffTakesTheItemWithoutRecording() {
        var state = reading()

        XCTAssertEqual(state.takeItemForHandOff(), item)
        XCTAssertNil(state.item)
        XCTAssertEqual(state.scope, .all)
        XCTAssertEqual(state.column, .content)
    }
}
