import XCTest
import CabalmailKit
@testable import CabalmailUI

// The model half of handing a full-swiped row's slot a new row (see
// `MessageListViewModel+RowReplacement.swift`): which slots get one and when.
// `FullSwipeRowReplacementTests` drives what that does to SwiftUI's held-open
// reveal; these pin the bookkeeping on every runner.
@MainActor
final class MessageListRowReplacementTests: XCTestCase {

    private func makeModel(
        imap: FakeImapClient = FakeImapClient(),
        uids: [UInt32],
        folderPath: String = "INBOX"
    ) throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: uids.map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) },
            folderPath: folderPath
        )
        model.window!.totalMessages = UInt32(uids.count)
        return model
    }

    private func generations(_ model: MessageListViewModel, count: Int) -> [Int] {
        model.rowSlots(count: count).map(\.generation)
    }

    /// The identity of `uid`'s row in `folder` (the model's INBOX unless named).
    private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
        MessageRef(folder: folder, uid: uid)
    }

    func testSlotsAreKeyedByIndexUntilARowIsReplaced() throws {
        let model = try makeModel(uids: [1, 2, 3])
        let slots = model.rowSlots(count: 3)
        XCTAssertEqual(slots.map(\.index), [0, 1, 2])
        XCTAssertEqual(slots.map(\.generation), [0, 0, 0], "nothing replaced yet, so nothing is rebuilt")
        XCTAssertEqual(model.rowSlot(at: 1), slots[1], "scrolling must address the slot the list draws")
    }

    func testReplacingARowRenewsTheSlotItsMessageOccupies() throws {
        let model = try makeModel(uids: [5, 6, 7])
        model.window!.windowStart = 10
        model.window!.totalMessages = 13

        model.replaceRows(showing: [ref(6)])

        XCTAssertEqual(model.rowSlot(at: 11).generation, 1, "UID 6 sits at absolute index 10 + 1")
        XCTAssertEqual(model.rowSlot(at: 10).generation, 0)
        XCTAssertEqual(model.rowSlot(at: 12).generation, 0)
        XCTAssertEqual(model.rowGenerations, [ref(6): 1], "the filtered list's row for UID 6 is renewed too")
        XCTAssertEqual(model.rowSlots(count: 13)[11], model.rowSlot(at: 11))
        // What the filtered / search list draws (`MessageListView.virtualizedList`).
        XCTAssertEqual(
            MessageRowIdentity.identify(model.envelopes, generations: model.rowGenerations).map(\.id.generation),
            [0, 1, 0],
            "the filtered list builds UID 6 a new row and leaves the others"
        )
    }

    func testDisposeReplacesTheSwipedRowAsTheMessageLeaves() async throws {
        let model = try makeModel(uids: [1, 2, 3])

        await model.dispose(model.envelopes[0])

        XCTAssertEqual(model.envelopes.map(\.uid), [2, 3])
        XCTAssertEqual(
            generations(model, count: 2), [1, 0],
            "the message moving up into the swiped row's slot must get a new row, not the held-open one"
        )
    }

    func testAFailedDisposeStillReplacesTheRow() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        let model = try makeModel(imap: imap, uids: [1, 2, 3])

        await model.dispose(model.envelopes[0])

        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2, 3], "an early failure leaves the message in place")
        XCTAssertEqual(
            generations(model, count: 3), [1, 0, 0],
            "the message stays, but in a new row: the swiped one may be held open behind its own button"
        )
        XCTAssertEqual(model.rowGenerations[ref(1)], 1)
        XCTAssertEqual(
            MessageRowIdentity.identify(model.envelopes, generations: model.rowGenerations).map(\.id.generation),
            [1, 0, 0],
            "in the filtered list too"
        )
    }

    func testTheSlotThatWasSwipedIsReplacedEvenIfTheListShifts() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.move)
        let model = try makeModel(imap: imap, uids: [1, 2, 3])

        let dispose = Task { await model.dispose(model.envelopes[0]) }
        await imap.awaitHeld(.move)
        // New mail lands above the leaving row mid-animation: the message moves
        // down a slot, but the row that was swiped -- and is held open -- is
        // still slot 0.
        model.envelopes.insert(TestFixtures.makeEnvelope(uid: 9, flags: [.seen]), at: 0)
        model.window!.totalMessages = 4
        let left = await eventually { !model.envelopes.contains { $0.uid == 1 } }
        XCTAssertTrue(left)

        XCTAssertEqual(model.envelopes.map(\.uid), [9, 2, 3])
        XCTAssertEqual(model.rowSlot(at: 0).generation, 1, "the slot the swipe happened in is renewed")
        XCTAssertEqual(model.rowSlot(at: 1).generation, 1, "and so is the slot the message had moved to")

        await imap.releaseHeld(.move)
        await dispose.value
    }

    func testPurgeReplacesTheCondemnedRowsBeforeTheyLeave() async throws {
        let model = try makeModel(uids: [1, 2, 3], folderPath: FolderTree.trashPath)

        await model.purgeMessages(refs: [ref(2, in: FolderTree.trashPath)])

        XCTAssertEqual(model.envelopes.map(\.uid), [1, 3])
        XCTAssertEqual(
            generations(model, count: 2), [0, 1],
            "a full swipe's Delete Forever held its row open while the dialog asked; the next message needs a new row"
        )
    }

    func testARowReportingInBeforeTheOneItReplacesLeavesKeepsItsIndexVisible() throws {
        let model = try makeModel(uids: [1, 2, 3])
        model.window!.noteRowVisible(0)
        model.window!.noteRowVisible(1)

        // A replaced row is one row leaving its index and another arriving at
        // it, and SwiftUI doesn't order their callbacks.
        model.window!.noteRowVisible(0)
        model.window!.noteRowHidden(0)

        XCTAssertEqual(model.window!.firstVisibleRow, 0, "slot 0 is still on screen; PgUp must not skip it")
        XCTAssertEqual(model.window!.lastVisibleRow, 1)
        model.window!.noteRowHidden(0)
        XCTAssertEqual(model.window!.firstVisibleRow, 1)
    }

    private func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
