import XCTest
import CabalmailKit
@testable import Cabalmail

// Phase 5 of docs/0.11.x/multi-select-bulk-operations.md: selection-set
// mutations, optimistic bulk state on success, rollback on failure, and
// partial-failure rollback granularity, all against MessageListViewModel
// with a scripted ImapClient.
@MainActor
final class BulkSelectionTests: XCTestCase {

    // MARK: - Selection mutations

    func testToggleSelectionFlipsMembership() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.toggleSelection(model.envelopes[0])
        XCTAssertEqual(model.selectedUIDs, [1])
        model.toggleSelection(model.envelopes[1])
        XCTAssertEqual(model.selectedUIDs, [1, 2])
        model.toggleSelection(model.envelopes[0])
        XCTAssertEqual(model.selectedUIDs, [2])
    }

    func testSelectAllVisibleRespectsFilterTab() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),                  // unread
                TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),  // read
                TestFixtures.makeEnvelope(uid: 3),                  // unread
            ]
        )
        model.filterTab = .unread
        model.selectAllVisible()
        XCTAssertEqual(model.selectedUIDs, [1, 3], "select-all scopes to the visible (filtered) rows")

        model.filterTab = .all
        model.selectAllVisible()
        XCTAssertEqual(model.selectedUIDs, [1, 2, 3])
    }

    func testExitBulkModeClearsSelection() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )
        model.bulkMode = true
        model.selectedUIDs = [1]
        model.exitBulkMode()
        XCTAssertFalse(model.bulkMode)
        XCTAssertTrue(model.selectedUIDs.isEmpty)
    }

    // MARK: - Optimistic flag state

    func testSetSeenAppliesAndStaysOnSuccess() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        appState.setUnreadCounts(["INBOX": 5])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)],
            appState: appState
        )

        await model.setSeen(true, uids: [1, 2])

        XCTAssertTrue(model.envelopes.allSatisfy { $0.flags.contains(.seen) })
        XCTAssertNil(model.errorMessage)
        // Both rows transitioned unread -> read, so the badge dropped by 2.
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 3)
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.uids, [1, 2])
        XCTAssertEqual(calls.first?.flags, [.seen])
    }

    func testSetSeenSkipsUnreadDeltaForNonTransitions() async throws {
        // Marking an already-read message read must not move the badge.
        let imap = FakeImapClient()
        let appState = AppState()
        appState.setUnreadCounts(["INBOX": 5])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),                  // unread -> transitions
                TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),  // already read
            ],
            appState: appState
        )

        await model.setSeen(true, uids: [1, 2])

        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 4, "only the real transition counts")
    }

    func testSetSeenRevertsAllOnTotalFailure() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([
            .failure(CabalmailError.server(code: "500", message: "unable")),
        ])
        let appState = AppState()
        appState.setUnreadCounts(["INBOX": 5])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)],
            appState: appState
        )

        await model.setSeen(true, uids: [1, 2])

        XCTAssertTrue(
            model.envelopes.allSatisfy { !$0.flags.contains(.seen) },
            "a failed group reverts every row"
        )
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 5, "no transition landed")
    }

    // MARK: - Partial-failure granularity

    func testSetSeenPartialFailureRevertsOnlyFailedRows() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([
            .failure(CabalmailError.bulkPartialFailure(succeeded: [1], failed: [2])),
        ])
        let appState = AppState()
        appState.setUnreadCounts(["INBOX": 5])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)],
            appState: appState
        )

        await model.setSeen(true, uids: [1, 2])

        let byUID = Dictionary(uniqueKeysWithValues: model.envelopes.map { ($0.uid, $0) })
        XCTAssertTrue(byUID[1]!.flags.contains(.seen), "the succeeded row keeps the change")
        XCTAssertFalse(byUID[2]!.flags.contains(.seen), "the failed row reverts")
        XCTAssertEqual(model.errorMessage, "Updated 1 of 2 messages. 1 could not be updated.")
        XCTAssertEqual(appState.folderUnreadCounts["INBOX"], 4, "only the landed transition counts")
    }

    func testPartialFailureRevertRestoresPreOpState() async throws {
        // The failed row was ALREADY read before the op: the revert must
        // restore that state, not blindly flip it to unread.
        let imap = FakeImapClient()
        await imap.scriptFlagResults([
            .failure(CabalmailError.bulkPartialFailure(succeeded: [1], failed: [2])),
        ])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [
                TestFixtures.makeEnvelope(uid: 1),
                TestFixtures.makeEnvelope(uid: 2, flags: [.seen]),
            ]
        )

        await model.setSeen(true, uids: [1, 2])

        let byUID = Dictionary(uniqueKeysWithValues: model.envelopes.map { ($0.uid, $0) })
        XCTAssertTrue(
            byUID[2]!.flags.contains(.seen),
            "a failed row that already carried the target flag keeps it"
        )
    }

    // MARK: - Moves

    func testMoveRemovesRowsAndSelectionOnSuccess() async throws {
        let imap = FakeImapClient()
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.selectedUIDs = [1, 2]

        await model.moveMessages(uids: [1, 2], to: "Archive")

        XCTAssertTrue(model.envelopes.isEmpty)
        XCTAssertTrue(model.selectedUIDs.isEmpty)
        let calls = await imap.moveCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.uids, [1, 2])
        XCTAssertEqual(calls.first?.destination, "Archive")
    }

    func testMovePartialFailureRestoresOnlyFailedRows() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([
            .failure(CabalmailError.bulkPartialFailure(succeeded: [1], failed: [2])),
        ])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )

        await model.moveMessages(uids: [1, 2], to: "Archive")

        XCTAssertEqual(
            model.envelopes.map(\.uid), [2],
            "the failed row is restored; the moved row stays gone"
        )
        XCTAssertEqual(model.errorMessage, "Moved 1 of 2 messages. 1 could not be moved.")
        XCTAssertTrue(
            model.pendingRemovedUIDs.isEmpty,
            "refresh shields drop once the batch settles"
        )
    }

    func testMoveTotalFailureRestoresEverything() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([
            .failure(CabalmailError.server(code: "500", message: "unable")),
        ])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )

        await model.moveMessages(uids: [1, 2], to: "Archive")

        XCTAssertEqual(Set(model.envelopes.map(\.uid)), [1, 2])
        XCTAssertNotNil(model.errorMessage)
    }

    func testDisposeProceedsWhenSeenMarkingPartiallyFails() async throws {
        // Dispose marks \Seen before the move (archived == read). A partial
        // miss on that cosmetic step must not abort the move itself.
        let imap = FakeImapClient()
        await imap.scriptFlagResults([
            .failure(CabalmailError.bulkPartialFailure(succeeded: [1], failed: [2])),
        ])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )

        await model.disposeMessages(uids: [1, 2], action: .archive)

        XCTAssertTrue(model.envelopes.isEmpty, "the move ran despite the partial seen-marking")
        let moves = await imap.moveCalls
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.uids, [1, 2])
    }
}
