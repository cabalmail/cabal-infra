import XCTest
@testable import CabalmailUI

/// A message dropped on a sidebar folder moves, whether or not SwiftUI
/// decodes a payload from the drag (`AppState.moveDropped`).
///
/// On the touchscreen MacBook Pro, a single message dragged onto a folder
/// was accepted and nothing moved: the folder's drop handler got no payload
/// (Settings → Debug Log: "Dropped 0 message(s) … from 0 payload(s)"), since
/// the drag offers the message's `.eml` ahead of the move reference. A drag
/// of several messages, which offers only the move reference, moved. The
/// folder now falls back to the drag this app lifted moments before.
@MainActor
final class AppStateMoveDropTests: XCTestCase {
    private let list = UUID()
    private let items = [MessageDragItem(uid: 7, sourceFolder: "INBOX")]
    private let liftedAt = Date(timeIntervalSince1970: 1_000_000)

    func testADecodedPayloadMovesItsOwnMessages() {
        let appState = AppState()
        let decoded = [MessageDragItem(uid: 9, sourceFolder: "Archive")]
        let other = UUID()
        appState.noteLiftedDrag(items: items, from: list, at: liftedAt)

        XCTAssertEqual(appState.moveDropped(decoded, from: other, to: "Junk", at: liftedAt), .decoded)
        XCTAssertEqual(appState.pendingMoveRequest?.items, decoded)
        XCTAssertEqual(appState.pendingMoveRequest?.sourceList, other)
        XCTAssertNil(appState.liftedMessageDrag, "a lifted drag outlived its drop")
    }

    /// The single-message drag from the device: no payload, so the drag the
    /// app lifted is moved, by the list it lifted from.
    func testADropWithNoPayloadMovesTheDragThisAppLifted() {
        let appState = AppState()
        appState.noteLiftedDrag(items: items, from: list, at: liftedAt)

        let outcome = appState.moveDropped([], from: nil, to: "Archive", at: liftedAt.addingTimeInterval(3))

        XCTAssertEqual(outcome, .lifted, "a drop with no payload moved nothing")
        XCTAssertEqual(appState.pendingMoveRequest?.items, items)
        XCTAssertEqual(appState.pendingMoveRequest?.destination, "Archive")
        XCTAssertEqual(appState.pendingMoveRequest?.sourceList, list)
        XCTAssertTrue(appState.pendingMoveRequest?.isPerformed(by: list) == true)
    }

    /// Used once: a second empty drop has nothing to move.
    func testTheLiftedDragMovesOnce() {
        let appState = AppState()
        appState.noteLiftedDrag(items: items, from: list, at: liftedAt)
        _ = appState.moveDropped([], from: nil, to: "Archive", at: liftedAt)
        let tick = appState.moveRequestTick

        XCTAssertEqual(appState.moveDropped([], from: nil, to: "Junk", at: liftedAt), .nothing)
        XCTAssertEqual(appState.moveRequestTick, tick, "the lifted drag moved twice")
    }

    /// A drag abandoned long ago, or never lifted here, moves nothing.
    func testAStaleOrMissingDragMovesNothing() {
        let stale = AppState()
        stale.noteLiftedDrag(items: items, from: list, at: liftedAt)
        let late = liftedAt.addingTimeInterval(LiftedMessageDrag.lifetime + 1)
        XCTAssertEqual(stale.moveDropped([], from: nil, to: "Archive", at: late), .nothing)
        XCTAssertNil(stale.pendingMoveRequest)

        let none = AppState()
        XCTAssertEqual(none.moveDropped([], from: nil, to: "Archive", at: liftedAt), .nothing)
        XCTAssertNil(none.pendingMoveRequest)
    }
}
