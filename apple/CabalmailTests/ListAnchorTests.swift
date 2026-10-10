import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where a folder list is scrolled (`ListAnchor`), and what a list does with
/// one once it has appeared and loaded: find the message's row by
/// Message-ID, then UID, then fall back to its position, without mistaking a
/// message shifted out of the loaded rows for one that is gone.
final class ListAnchorTests: XCTestCase {
    /// `count` rows starting at absolute `start`, row `i` holding UID
    /// `1000 - i` and that UID's Message-ID.
    private func rows(_ count: Int, from start: Int = 0) -> [Envelope] {
        (start..<(start + count)).map { index in
            let uid = UInt32(1000 - index)
            return TestFixtures.makeEnvelope(uid: uid, messageId: "<\(uid)@example.com>")
        }
    }

    private func anchor(index: Int, uid: UInt32?, messageID: String? = nil) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(folderPath: "INBOX", messageID: messageID, uid: uid, index: index))
    }

    // MARK: The value

    func testTheTopOfTheListStoresNothing() {
        XCTAssertNil(ListAnchor(folderPath: "INBOX", messageID: "<a@x>", uid: 9, index: 0))
        XCTAssertNil(ListAnchor(folderPath: "INBOX", messageID: "<a@x>", uid: 9, index: -1))
        XCTAssertNotNil(ListAnchor(folderPath: "INBOX", messageID: nil, uid: nil, index: 1))
    }

    func testAnEmptyMessageIDIsNone() throws {
        XCTAssertNil(try anchor(index: 3, uid: 9, messageID: "").messageID)
    }

    func testMovedKeepsTheIdentity() throws {
        let anchor = try anchor(index: 300, uid: 700, messageID: "<700@example.com>")
        let moved = try XCTUnwrap(anchor.moved(to: 304))
        XCTAssertEqual(moved.index, 304)
        XCTAssertEqual(moved.uid, 700)
        XCTAssertEqual(moved.messageID, "<700@example.com>")
        XCTAssertEqual(moved.folderPath, "INBOX")
        XCTAssertNil(anchor.moved(to: 0), "the top stores nothing")
    }

    // MARK: Finding the row

    func testTheMessageIsFoundByMessageID() throws {
        // Three messages arrived since: UID 700 sat at 297 and is at 300 now.
        let loaded = rows(200, from: 203)
        let anchor = try anchor(index: 297, uid: nil, messageID: "<700@example.com>")
        XCTAssertEqual(anchor.row(in: loaded, windowStart: 203), 300)
        XCTAssertEqual(
            anchor.landing(rows: loaded, windowStart: 203, slotCount: 1000, countKnown: true), .found(row: 300)
        )
    }

    /// The same Message-ID twice (a copy in the folder): the row nearer the
    /// anchor's position, and the lower on a tie.
    func testOfTwoRowsWithTheMessageIDTheNearerWins() throws {
        var loaded = rows(20)
        loaded[4] = TestFixtures.makeEnvelope(uid: 1, messageId: "<twin@example.com>")
        loaded[12] = TestFixtures.makeEnvelope(uid: 2, messageId: "<twin@example.com>")
        func row(nearest index: Int) throws -> Int? {
            try anchor(index: index, uid: nil, messageID: "<twin@example.com>").row(in: loaded, windowStart: 0)
        }
        XCTAssertEqual(try row(nearest: 11), 12)
        XCTAssertEqual(try row(nearest: 5), 4)
        XCTAssertEqual(try row(nearest: 8), 4, "a tie takes the lower")
    }

    func testWithoutAMessageIDMatchTheUIDFinds() throws {
        let loaded = rows(50)
        XCTAssertEqual(try anchor(index: 7, uid: 990).row(in: loaded, windowStart: 0), 10)
        let stale = try anchor(index: 7, uid: 990, messageID: "<gone@example.com>")
        XCTAssertEqual(stale.row(in: loaded, windowStart: 0), 10, "the UID, when the Message-ID is not there")
    }

    // MARK: Landing without the message

    /// The loaded rows reach well past the anchor's position on both sides
    /// and the message is not among them: it is gone, and the list opens at
    /// the position it had.
    func testAMessageGoneFromTheLoadedRowsLandsOnItsPosition() throws {
        let anchor = try anchor(index: 100, uid: 5, messageID: "<gone@example.com>")
        XCTAssertEqual(
            anchor.landing(rows: rows(300), windowStart: 0, slotCount: 1000, countKnown: true), .position(row: 100)
        )
    }

    /// Near the edge of the loaded rows the message may only have been
    /// shifted past it by mail that arrived since, so the list loads around
    /// the position and looks again rather than settle on the wrong message.
    func testAMissNearTheEdgeOfTheLoadedRowsIsAGuess() throws {
        let anchor = try anchor(index: 595, uid: 5, messageID: "<shifted@example.com>")
        XCTAssertEqual(
            anchor.landing(rows: rows(600), windowStart: 0, slotCount: 1000, countKnown: true), .guess(row: 595)
        )
    }

    func testAnUnloadedPositionIsAGuess() throws {
        let anchor = try anchor(index: 400, uid: 600, messageID: "<600@example.com>")
        XCTAssertEqual(
            anchor.landing(rows: rows(50), windowStart: 0, slotCount: 1000, countKnown: true), .guess(row: 400)
        )
    }

    /// Offline, the list is only as long as its loaded rows: an anchor past
    /// them waits for the folder's count rather than land on the last row.
    func testPastTheLoadedRowsBeforeTheCountWaits() throws {
        let anchor = try anchor(index: 400, uid: 600)
        XCTAssertEqual(anchor.landing(rows: rows(50), windowStart: 0, slotCount: 50, countKnown: false), .wait)
    }

    func testAFolderThatShrankLandsOnItsLastRow() throws {
        let anchor = try anchor(index: 400, uid: 5, messageID: "<gone@example.com>")
        XCTAssertEqual(
            anchor.landing(rows: rows(120), windowStart: 0, slotCount: 120, countKnown: true), .position(row: 119)
        )
    }

    func testAnEmptyFolderDropsTheAnchor() throws {
        XCTAssertEqual(
            try anchor(index: 4, uid: 9).landing(rows: [], windowStart: 0, slotCount: 0, countKnown: true), .drop
        )
    }

    func testAnEmptyFolderBeforeItsCountWaits() throws {
        XCTAssertEqual(
            try anchor(index: 4, uid: 9).landing(rows: [], windowStart: 0, slotCount: 0, countKnown: false), .wait
        )
    }

    // MARK: Naming a row

    func testAnAnchorNamesItsMessageByMessageIDThenUID() throws {
        let anchor = try anchor(index: 3, uid: 9, messageID: "<nine@example.com>")
        XCTAssertTrue(anchor.names(TestFixtures.makeEnvelope(uid: 44, messageId: "<nine@example.com>")))
        XCTAssertFalse(anchor.names(TestFixtures.makeEnvelope(uid: 9, messageId: "<other@example.com>")))
        XCTAssertTrue(anchor.names(TestFixtures.makeEnvelope(uid: 9)), "by UID when the row has no Message-ID")
        let bare = try XCTUnwrap(ListAnchor(folderPath: "INBOX", messageID: nil, uid: nil, index: 3))
        XCTAssertFalse(bare.names(TestFixtures.makeEnvelope(uid: 9)), "a place recorded on a placeholder names nothing")
    }
}
