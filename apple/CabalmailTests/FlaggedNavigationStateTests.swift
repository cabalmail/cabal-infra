import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// `FlaggedNavigationState`: a window's place in the Flagged view, one pure
/// transition at a time.
final class FlaggedNavigationStateTests: XCTestCase {
    private typealias Record = FlaggedNavigationState.Record

    private let message = FlaggedRow.mail(
        Envelope(uid: 4, subject: "m4", from: [], flags: [.flagged], folder: "Lists"),
        MessageRef(folder: "Lists", uid: 4)
    )
    private let article = FlaggedRow.feed(
        RssItem(feedId: "f", subscriptionId: "s", itemId: "a", sortKey: "a", isFavorite: true)
    )

    private func opened(_ door: ResumeSession.Section = .mail) -> FlaggedNavigationState {
        var state = FlaggedNavigationState()
        _ = state.open(from: door)
        return state
    }

    // MARK: Opening and closing

    func testAWindowStartsOffTheView() {
        let state = FlaggedNavigationState()

        XCTAssertFalse(state.isOpen)
        XCTAssertNil(state.door)
        XCTAssertEqual(state.column, .sidebar)
    }

    func testTheEntryOpensTheViewOnItsListThroughItsDoor() {
        var state = FlaggedNavigationState()

        XCTAssertEqual(state.open(from: .feeds), [.opened(.feeds)])

        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.door, .feeds)
        XCTAssertEqual(state.column, .content)
        XCTAssertNil(state.item)
        XCTAssertEqual(state.visit, 1)
    }

    func testTheEntryPickedAgainClosesTheReaderAndIsNoNewVisit() {
        var state = opened()
        _ = state.selectItem(message)

        XCTAssertEqual(state.open(from: .mail), [.item(nil)])
        XCTAssertNil(state.item)
        XCTAssertEqual(state.column, .content)
        XCTAssertEqual(state.visit, 1)

        XCTAssertEqual(state.open(from: .mail), [], "already on its list")
    }

    func testTheOtherDoorMovesTheViewAndStartsAVisit() {
        var state = opened(.mail)
        _ = state.selectItem(message)

        XCTAssertEqual(state.open(from: .feeds), [.opened(.feeds)])

        XCTAssertEqual(state.door, .feeds)
        XCTAssertNil(state.item)
        XCTAssertEqual(state.visit, 2)
    }

    func testClosingDropsEverythingAndSaysSoOnce() {
        var state = opened()
        _ = state.selectItem(article)

        XCTAssertEqual(state.close(), [.closed])
        XCTAssertFalse(state.isOpen)
        XCTAssertNil(state.door)
        XCTAssertNil(state.item)

        XCTAssertEqual(state.close(), [], "nothing was open")
    }

    // MARK: The open row

    func testARowOpensTheReaderAndIsRecorded() {
        var state = opened()

        XCTAssertEqual(state.selectItem(message), [.item(message)])
        XCTAssertEqual(state.item, message)
        XCTAssertEqual(state.column, .detail)

        XCTAssertEqual(state.selectItem(article), [.item(article)])
        XCTAssertEqual(state.item, article)
    }

    /// A row patched in place (read, a flag) is the same item: the reader's
    /// copy follows it and nothing is recorded again.
    func testTheSameRowPatchedInPlaceRecordsNothing() {
        var state = opened()
        _ = state.selectItem(message)
        let read = FlaggedRow.mail(
            Envelope(uid: 4, subject: "m4", from: [], flags: [.flagged, .seen], folder: "Lists"),
            MessageRef(folder: "Lists", uid: 4)
        )

        XCTAssertEqual(state.selectItem(read), [])
        XCTAssertEqual(state.item, read)
        XCTAssertEqual(state.column, .detail)
    }

    func testClosingTheRowGoesBackToTheList() {
        var state = opened()
        _ = state.selectItem(message)

        XCTAssertEqual(state.selectItem(nil), [.item(nil)])
        XCTAssertEqual(state.column, .content)
        XCTAssertTrue(state.isOpen)
    }

    func testARowSelectedOffTheViewIsNothing() {
        var state = FlaggedNavigationState()

        XCTAssertEqual(state.selectItem(message), [])
        XCTAssertNil(state.item)
    }

    // MARK: A collapsed stack's column

    func testBackFromTheReaderDropsTheRowSoItCanBeOpenedAgain() {
        var state = opened()
        _ = state.selectItem(message)

        XCTAssertEqual(state.setColumn(.content), [.item(nil)])
        XCTAssertNil(state.item)
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.selectItem(message), [.item(message)])
    }

    /// Back from the list ends the visit, but the door stays named, so the
    /// stack's content column goes on drawing the view while it slides away.
    func testBackFromTheListEndsTheVisitAndKeepsTheDoor() {
        var state = opened(.feeds)

        XCTAssertEqual(state.setColumn(.sidebar), [.closed])

        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.door, .feeds)
        XCTAssertEqual(state.column, .sidebar)

        // Picked again from there, it is a new visit.
        XCTAssertEqual(state.open(from: .feeds), [.opened(.feeds)])
        XCTAssertEqual(state.visit, 2)
    }

    func testAColumnMoveOffTheViewIsNothing() {
        var state = FlaggedNavigationState()
        XCTAssertEqual(state.setColumn(.content), [])
        XCTAssertEqual(state.column, .sidebar)

        var backedOut = opened()
        _ = backedOut.setColumn(.sidebar)
        XCTAssertEqual(backedOut.setColumn(.content), [], "the stack moved on to its own list")
        XCTAssertFalse(backedOut.isOpen)
    }

    // MARK: A layout swap

    func testASwapParksTheOpenRowAndStartsTheNewTreeOnTheList() {
        var state = opened()
        _ = state.selectItem(article)

        state.handOff()

        XCTAssertTrue(state.isOpen, "the window is still on the view")
        XCTAssertNil(state.item)
        XCTAssertEqual(state.column, .content)
        XCTAssertEqual(state.takeParked(), .row(article))
        XCTAssertNil(state.takeParked(), "once")
    }

    /// Two trees inside one swap: the first one's list never took the row,
    /// and the second tree's hand-off must not lose it.
    func testASecondSwapBeforeTheListTookTheRowKeepsItParked() {
        var state = opened()
        _ = state.selectItem(message)

        state.handOff()
        state.handOff()

        XCTAssertEqual(state.takeParked(), .row(message))
    }

    func testASwapOffTheViewParksNothing() {
        var state = FlaggedNavigationState()

        state.handOff()

        XCTAssertNil(state.parked)
        XCTAssertEqual(state.column, .sidebar)
    }

    func testAPickOrAClosingDropsWhatWasParked() {
        var state = opened()
        _ = state.selectItem(message)
        state.handOff()
        _ = state.close()
        XCTAssertNil(state.parked)

        var reopened = opened()
        _ = reopened.selectItem(message)
        reopened.handOff()
        _ = reopened.open(from: .feeds)
        XCTAssertNil(reopened.parked, "another door is another visit")
    }

    func testTheSplitTakingOverMovesTheDoorAndNothingElse() {
        var state = opened(.feeds)
        _ = state.selectItem(article)
        state.handOff()

        state.rehome(to: .mail)

        XCTAssertEqual(state.door, .mail)
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.visit, 1, "the same visit")
        XCTAssertEqual(state.takeParked(), .row(article))

        var closed = FlaggedNavigationState()
        closed.rehome(to: .mail)
        XCTAssertNil(closed.door, "off the view there is nothing to move")
    }

    // MARK: A stored route

    func testAStoredRouteOpensTheViewWithItsItemParkedByIdentity() {
        let ref = ItemRef.feed(feedID: "f", sortKey: "a")

        var state = FlaggedNavigationState(door: .feeds, item: ref)

        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.door, .feeds)
        XCTAssertNil(state.item, "the list opens it once its rows have loaded")
        XCTAssertEqual(state.takeParked(), .ref(ref))

        let bare = FlaggedNavigationState(door: .mail, item: nil)
        XCTAssertTrue(bare.isOpen)
        XCTAssertNil(bare.parked)
    }
}
