import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression tests for #737: the All/Unread/Flagged filter-pill counts read
// `unseen` / `flagged`, which only STATUS used to write — so a flag or read
// change (row swipe, detail-view toolbar, mark-as-read on open) updated the
// row's own indicators but left the pill counts stale until the next server
// refetch. `applyOptimisticFlag` now adjusts the counters whenever a flag
// actually flips, which covers every optimistic path (list toggle,
// detail-view signal, bulk, and their error reverts) without double-counting.
@MainActor
final class MessageListPillCountTests: XCTestCase {

    private func makeModel(imap: FakeImapClient = FakeImapClient()) throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),                  // unread
                TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),  // read
            ]
        )
        // Server-sourced STATUS counts as of the last refresh.
        model.totalMessages = 2
        model.unseen = 1
        model.flagged = 0
        return model
    }

    func testDetailOriginatedFlagToggleUpdatesFlaggedPill() throws {
        let model = try makeModel()
        // The reader's flag toggle reaches the list via applyFlagChange.
        model.applyFlagChange(uid: 2, flag: .flagged, added: true)
        XCTAssertEqual(model.flagged, 1, "flagging from the reader bumps the Flagged pill")
        // A duplicate signal for an already-flagged row must not double-count.
        model.applyFlagChange(uid: 2, flag: .flagged, added: true)
        XCTAssertEqual(model.flagged, 1)
        model.applyFlagChange(uid: 2, flag: .flagged, added: false)
        XCTAssertEqual(model.flagged, 0)
    }

    func testDetailOriginatedMarkAsReadUpdatesUnreadPill() throws {
        let model = try makeModel()
        // Mark-as-read on open reaches the list via the same signal.
        model.applyFlagChange(uid: 1, flag: .seen, added: true)
        XCTAssertEqual(model.unseen, 0, "reading from the reader drops the Unread pill")
        model.applyFlagChange(uid: 1, flag: .seen, added: false)
        XCTAssertEqual(model.unseen, 1)
    }

    func testListToggleUpdatesAndFailureReverts() async throws {
        let imap = FakeImapClient()
        let model = try makeModel(imap: imap)
        // Successful swipe/context-menu toggle adjusts the pill...
        await model.setFlag(.seen, add: true, envelope: model.envelopes[0])
        XCTAssertEqual(model.unseen, 0)
        // ...and a failed write reverts the count along with the row.
        await imap.scriptFlagResults([.failure(CabalmailError.protocolError("boom"))])
        await model.setFlag(.flagged, add: true, envelope: model.envelopes[1])
        XCTAssertEqual(model.flagged, 0, "failed flag write reverts the Flagged pill")
    }

    func testUnrelatedFlagLeavesPillsAlone() throws {
        let model = try makeModel()
        model.applyFlagChange(uid: 1, flag: .answered, added: true)
        XCTAssertEqual(model.unseen, 1)
        XCTAssertEqual(model.flagged, 0)
    }

    // MARK: - #850: a row disposed from the reader

    func testDisposedUnreadRowDropsTheUnreadPill() throws {
        let model = try makeModel()
        // The reader archives an unread message: the `\Seen` marking rides
        // along with the move server-side, and the prune signal is all the
        // list gets before the row is gone.
        model.pruneEnvelope(uid: 1)
        XCTAssertEqual(
            model.unseen, 0,
            "a message archived from the reader left the folder unread — the pill must follow"
        )
    }

    func testDisposedReadRowLeavesTheUnreadPill() throws {
        let model = try makeModel()
        model.pruneEnvelope(uid: 2)
        XCTAssertEqual(model.unseen, 1, "the read row was never in the Unread count")
    }

    func testFlagSignalAndPruneCountTheDisposedRowOnce() throws {
        let model = try makeModel()
        // The reader posts both signals in one turn; if the flag signal wins
        // the race the row is already `\Seen` by the time it's pruned.
        model.applyFlagChange(uid: 1, flag: .seen, added: true)
        model.pruneEnvelope(uid: 1)
        XCTAssertEqual(model.unseen, 0, "the departed message must be subtracted exactly once")
    }

    func testPruneOfAnUnloadedUIDLeavesTheUnreadPill() throws {
        let model = try makeModel()
        model.pruneEnvelope(uid: 99)
        XCTAssertEqual(
            model.unseen, 1,
            "a signal for a UID we never had loaded says nothing about the unread count"
        )
    }
}
