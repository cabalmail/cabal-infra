import XCTest
import CabalmailKit
@testable import Cabalmail

/// The after-dispose advance policies (`advanceTarget(after:following:)` and
/// its per-policy helpers) against the list order the view model holds.
/// Fixtures list rows newest (highest UID) first, matching the production
/// sort, and `flags: [.seen]` marks a row read.
@MainActor
final class DisposeAdvanceTests: XCTestCase {
    private func makeModel(_ envelopes: [Envelope]) throws -> MessageListViewModel {
        try TestFixtures.makeModel(imap: FakeImapClient(), envelopes: envelopes)
    }

    private func envelope(_ model: MessageListViewModel, uid: UInt32) throws -> Envelope {
        try XCTUnwrap(model.envelopes.first { $0.uid == uid })
    }

    // MARK: - Next message

    func testNextReturnsTheRowBelowRegardlessOfReadState() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        let target = model.nextEnvelope(after: try envelope(model, uid: 4))
        XCTAssertEqual(target?.uid, 3)
    }

    func testNextFromTheBottomRowFallsBackToTheRowAbove() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3),
        ])
        let target = model.nextEnvelope(after: try envelope(model, uid: 3))
        XCTAssertEqual(target?.uid, 4)
    }

    func testNextWithNoOtherRowsReturnsNil() throws {
        let model = try makeModel([TestFixtures.makeEnvelope(uid: 5)])
        XCTAssertNil(model.nextEnvelope(after: try envelope(model, uid: 5)))
    }

    // MARK: - Next unread

    func testNextUnreadSkipsReadRowsBelow() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        let target = model.nextUnreadEnvelope(after: try envelope(model, uid: 5))
        XCTAssertEqual(target?.uid, 2)
    }

    func testNextUnreadFallsBackToTheNearestUnreadAbove() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3),
            TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),
        ])
        let target = model.nextUnreadEnvelope(after: try envelope(model, uid: 3))
        XCTAssertEqual(target?.uid, 5)
    }

    // MARK: - Previous unread

    func testPreviousUnreadReturnsTheNearestUnreadAbove() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        let target = model.previousUnreadEnvelope(before: try envelope(model, uid: 3))
        XCTAssertEqual(target?.uid, 5)
    }

    func testPreviousUnreadFallsBackToTheNearestUnreadBelow() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        let target = model.previousUnreadEnvelope(before: try envelope(model, uid: 3))
        XCTAssertEqual(target?.uid, 2)
    }

    func testPreviousUnreadWithNoOtherUnreadReturnsNil() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
        ])
        XCTAssertNil(model.previousUnreadEnvelope(before: try envelope(model, uid: 4)))
    }

    // MARK: - First unread

    func testFirstUnreadReturnsTheTopmostUnread() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3),
        ])
        let target = model.firstUnreadEnvelope(excluding: try envelope(model, uid: 3))
        XCTAssertEqual(target?.uid, 4)
    }

    func testFirstUnreadSkipsTheDisposedMessageItself() throws {
        // The disposed row can still read as unread here: its optimistic
        // `\Seen` mark travels on a separate signal.
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3),
        ])
        let target = model.firstUnreadEnvelope(excluding: try envelope(model, uid: 5))
        XCTAssertEqual(target?.uid, 3)
    }

    func testFirstUnreadWithNoOtherUnreadReturnsNil() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
        ])
        XCTAssertNil(model.firstUnreadEnvelope(excluding: try envelope(model, uid: 5)))
    }

    // MARK: - Dispatch

    func testAdvanceTargetFollowsThePolicy() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 6),
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        let current = try envelope(model, uid: 4)
        XCTAssertEqual(model.advanceTarget(after: current, following: .next)?.uid, 3)
        XCTAssertEqual(model.advanceTarget(after: current, following: .nextUnread)?.uid, 2)
        XCTAssertEqual(model.advanceTarget(after: current, following: .previousUnread)?.uid, 6)
        XCTAssertEqual(model.advanceTarget(after: current, following: .firstUnread)?.uid, 6)
    }

    /// The mark-read variant shares the per-policy walks; what's distinct is
    /// `.stay` (always nil — the caller leaves the selection alone) and that
    /// the walks ignore `current`'s own read state, so the result is the
    /// same whether the optimistic `\Seen` flip has landed on the row yet.
    func testMarkReadAdvanceTargetFollowsThePolicy() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 6),
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 2),
        ])
        for currentFlags in [Set<Flag>(), [.seen]] {
            model.envelopes[2] = TestFixtures.makeEnvelope(uid: 4, flags: currentFlags)
            let current = try envelope(model, uid: 4)
            XCTAssertNil(model.markReadAdvanceTarget(after: current, following: .stay))
            XCTAssertEqual(model.markReadAdvanceTarget(after: current, following: .nextUnread)?.uid, 2)
            XCTAssertEqual(model.markReadAdvanceTarget(after: current, following: .previousUnread)?.uid, 6)
            XCTAssertEqual(model.markReadAdvanceTarget(after: current, following: .firstUnread)?.uid, 6)
        }
    }

    func testMarkReadAdvanceWithNoOtherUnreadReturnsNil() throws {
        let model = try makeModel([
            TestFixtures.makeEnvelope(uid: 5, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 4),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen]),
        ])
        let current = try envelope(model, uid: 4)
        for advance in MarkReadAdvance.allCases {
            XCTAssertNil(model.markReadAdvanceTarget(after: current, following: advance))
        }
    }
}
