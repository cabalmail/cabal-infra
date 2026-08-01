import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #843: an optimistic prune dropped the
// envelope but left `totalMessages` (the last STATUS count) untouched. The
// index-addressed list renders `max(totalMessages, loaded rows)` slots, so
// the vacated slot kept rendering a loading skeleton that could never
// resolve — the message it pointed at was gone — and the All filter pill
// kept counting it, until the next STATUS landed. On an unsubscribed folder
// (Drafts, where sending a draft prunes its row) nothing polls, so that ran
// to ~2 minutes; the human reported the same skeleton on archive elsewhere.
// Every optimistic prune and its revert now adjust the total with the row.
@MainActor
final class OptimisticPruneTotalTests: XCTestCase {

    private func makeModel(
        imap: FakeImapClient = FakeImapClient(),
        uids: [UInt32] = [1, 2],
        folderPath: String = "INBOX"
    ) throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: uids.map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) },
            folderPath: folderPath
        )
        // Server-sourced STATUS count as of the last refresh.
        model.totalMessages = UInt32(uids.count)
        return model
    }

    func testDisposeSignalledFromTheReaderDropsTheSlot() throws {
        // The send-a-draft path: ComposeView posts `signalDisposed`, the list
        // observes it and calls `pruneEnvelope`.
        let model = try makeModel(uids: [7], folderPath: "Drafts")

        model.pruneEnvelope(uid: 7)

        XCTAssertTrue(model.envelopes.isEmpty)
        XCTAssertEqual(
            model.totalMessages, 0,
            "the emptied Drafts folder must render no rows — a leftover total is a skeleton row"
        )
    }

    func testPruneOfAnUnloadedUIDLeavesTheTotalAlone() throws {
        let model = try makeModel(uids: [1, 2])

        model.pruneEnvelope(uid: 99)

        XCTAssertEqual(
            model.totalMessages, 2,
            "a signal for a UID we never had loaded says nothing about the folder total"
        )
    }

    func testSuccessfulDisposeDropsTheSlot() async throws {
        let model = try makeModel(uids: [1, 2])

        await model.dispose(model.envelopes[0])

        XCTAssertEqual(model.envelopes.map(\.uid), [2])
        XCTAssertEqual(model.totalMessages, 1)
    }

    func testFailedDisposeKeepsTheTotal() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        let model = try makeModel(imap: imap, uids: [1, 2])

        await model.dispose(model.envelopes[0])

        // The row never left `envelopes`, so the total never lost its slot.
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2])
        XCTAssertEqual(model.totalMessages, 2)
    }

    func testMoveToDropsTheSlotAndRestoresItOnFailure() async throws {
        let imap = FakeImapClient()
        let model = try makeModel(imap: imap, uids: [1, 2])

        await model.moveTo(model.envelopes[0], destination: "Archive")
        XCTAssertEqual(model.totalMessages, 1)

        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        await model.moveTo(model.envelopes[0], destination: "Archive")

        XCTAssertEqual(model.envelopes.map(\.uid), [2])
        XCTAssertEqual(
            model.totalMessages, 1,
            "a failed move puts the row back, so the folder total gets its slot back too"
        )
    }

    func testBulkMoveDropsEverySlotAndRevertsTogether() async throws {
        let imap = FakeImapClient()
        let model = try makeModel(imap: imap, uids: [1, 2, 3])

        await model.performMove(
            uidsBySource: ["INBOX": [1, 2]], to: "Archive", markSeenFirst: true
        )
        XCTAssertEqual(model.totalMessages, 1)

        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        await model.performMove(
            uidsBySource: ["INBOX": [3]], to: "Archive", markSeenFirst: true
        )

        XCTAssertEqual(model.envelopes.map(\.uid), [3])
        XCTAssertEqual(model.totalMessages, 1)
    }

    func testPurgeDropsEverySlot() async throws {
        let imap = FakeImapClient()
        let model = try makeModel(imap: imap, uids: [1, 2], folderPath: FolderTree.trashPath)

        await model.purgeMessages(uids: [1, 2])

        XCTAssertTrue(model.envelopes.isEmpty)
        XCTAssertEqual(model.totalMessages, 0)
    }

    func testSearchResultsKeepTheirOwnRowCount() throws {
        let model = try makeModel(uids: [1, 2])
        model.isSearchActive = true

        model.pruneEnvelope(uid: 1)

        XCTAssertEqual(
            model.totalMessages, 2,
            "search lists derive their row count from the results, not from a folder STATUS"
        )
    }
}
