import XCTest
import CabalmailKit
@testable import Cabalmail

// One message filed in two folders under the same UID: mail you send
// yourself lands in INBOX and in Sent with one Message-ID, and in a small
// mailbox the two UIDs can coincide. Nothing on the wire tells the copies
// apart -- the API path gives both the same Date-derived internalDate and a
// nil size -- so the rows below are identical except that the Sent copy is
// read, exactly as a cross-folder search returns them. The server sorts the
// Sent copy first. Before the fix both rows resolved to Sent, the
// cross-folder guard never fired, and a bulk action changed only the Sent
// copy whichever row the user was looking at.
@MainActor
final class SelfSentSearchCopyTests: XCTestCase {
    private let messageID = "<note-to-self@example.com>"

    private func sentCopy() -> Envelope {
        TestFixtures.makeEnvelope(uid: 9, flags: [.seen], messageId: messageID, subject: "note to self")
    }

    private func inboxCopy() -> Envelope {
        TestFixtures.makeEnvelope(uid: 9, messageId: messageID, subject: "note to self")
    }

    // MARK: - The index

    func testCopiesUnderOneUIDReportEveryFolder() {
        let index = SearchSourceFolderIndex([
            SearchedEnvelope(envelope: sentCopy(), folder: "Sent"),
            SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
        ])
        XCTAssertEqual(index.folders(for: inboxCopy()), ["Sent", "INBOX"])
        XCTAssertEqual(index.folders(for: sentCopy()), ["Sent", "INBOX"])
        // Single-row paths still get one answer: the first copy.
        XCTAssertEqual(index.folder(for: inboxCopy()), "Sent")
    }

    func testCopyOnALaterPageMakesTheFirstAmbiguous() {
        var index = SearchSourceFolderIndex([SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX")])
        XCTAssertEqual(index.folders(for: inboxCopy()), ["INBOX"])
        index.add([SearchedEnvelope(envelope: sentCopy(), folder: "Sent")])
        XCTAssertEqual(index.folders(for: inboxCopy()), ["INBOX", "Sent"])
        XCTAssertEqual(index.folder(for: inboxCopy()), "INBOX", "the earlier page's row still wins")
    }

    func testTheSameRowDeliveredTwiceIsNotTwoCopies() {
        // A chunked walk or a shifted page boundary can repeat a row; that is
        // one folder, not an ambiguity.
        let row = SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX")
        var index = SearchSourceFolderIndex([row, row])
        index.add([row])
        XCTAssertEqual(index.folders(for: inboxCopy()), ["INBOX"])
    }

    func testUnknownRowHasNoFolders() {
        XCTAssertEqual(SearchSourceFolderIndex().folders(for: inboxCopy()), [])
    }

    // MARK: - Bulk actions

    /// A cross-folder search holding both copies plus an unrelated message
    /// in Receipts (not Archive: a dispose to Archive skips rows already
    /// there, which would pass the dispose test for the wrong reason).
    private func selfSentSearchModel(imap: FakeImapClient) async throws -> MessageListViewModel {
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(envelope: sentCopy(), folder: "Sent"),
                SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
                SearchedEnvelope(
                    envelope: TestFixtures.makeEnvelope(uid: 4, messageId: "<receipt@example.com>"),
                    folder: "Receipts"
                ),
            ],
            totalEstimate: 3,
            nextCursor: nil,
            foldersSearched: ["Sent", "INBOX", "Receipts"],
            truncated: false
        ))
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "note"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.count, 3)
        return model
    }

    private func assertLeftUnchangedNotice(
        _ model: MessageListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            model.skippedNotice?.contains("left unchanged"), true,
            "the user is told why the copies were left alone", file: file, line: line
        )
        XCTAssertEqual(
            model.skippedNotice?.contains("Open each one"), false,
            "the reader can't open the second copy, so the note must not send the user there",
            file: file, line: line
        )
        XCTAssertNil(model.errorMessage, "a skipped row is not a failure", file: file, line: line)
    }

    func testBulkSeenLeavesBothCopiesAndActsOnTheRest() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.setSeen(true, uids: [9, 4])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"], "neither copy of the self-sent message is written")
        XCTAssertEqual(calls.first?.uids, [4])
        XCTAssertEqual(
            model.envelopes.filter { $0.uid == 9 }.map { $0.flags.contains(.seen) }, [true, false],
            "the Sent copy stays read and the INBOX copy stays unread"
        )
        assertLeftUnchangedNotice(model)
    }

    func testBulkFlagLeavesBothCopies() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.setFlagged(true, uids: [9])

        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(model.envelopes.allSatisfy { !$0.flags.contains(.flagged) })
        assertLeftUnchangedNotice(model)
    }

    func testBulkMoveLeavesBothCopiesInPlace() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        model.selectedUIDs = [9, 4]

        await model.moveMessages(uids: [9, 4], to: "Junk")

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"])
        XCTAssertEqual(calls.first?.uids, [4])
        XCTAssertEqual(model.envelopes.map(\.uid), [9, 9], "both copies stay listed")
        XCTAssertEqual(model.selectedUIDs, [9], "the rows left in place stay selected")
        assertLeftUnchangedNotice(model)
    }

    func testBulkArchiveLeavesBothCopiesInPlace() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.disposeMessages(uids: [9, 4], action: .archive)

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"])
        XCTAssertEqual(calls.first?.uids, [4])
        XCTAssertEqual(calls.first?.destination, "Archive")
        XCTAssertEqual(model.envelopes.map(\.uid), [9, 9])
        assertLeftUnchangedNotice(model)
    }

    func testCopyOnASecondPageStillStopsTheAction() async throws {
        // INBOX copy on page 1, Sent copy on page 2: only `add` sees both.
        let imap = FakeImapClient()
        let fillers = (100..<149).map {
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: UInt32($0)), folder: "INBOX")
        }
        await imap.scriptSearchPages([
            SearchResult(
                envelopes: [SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX")] + fillers,
                totalEstimate: 51, nextCursor: "c1", foldersSearched: ["INBOX", "Sent"], truncated: false
            ),
            SearchResult(
                envelopes: [SearchedEnvelope(envelope: sentCopy(), folder: "Sent")],
                totalEstimate: 51, nextCursor: nil, foldersSearched: ["INBOX", "Sent"], truncated: false
            ),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "note"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.count, 50, "page 1 alone; the copy arrives with the next page")
        await model.loadMoreSearchResults()
        XCTAssertEqual(model.envelopes.count, 51)

        await model.setSeen(true, uids: [9])

        let calls = await imap.flagCalls
        XCTAssertTrue(calls.isEmpty)
        assertLeftUnchangedNotice(model)
    }

    // MARK: - Dragging a selection

    func testSelectionDragLeavesBothCopiesInPlace() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        model.selectedUIDs = [9, 4]
        // What `dragItems(for:model:)` builds for that selection: a row per
        // selected UID, each routed through `sourceFolder(for:)`, which names
        // the first copy's folder for both copies.
        let items = model.envelopes.map { MessageDragItem(uid: $0.uid, sourceFolder: model.sourceFolder(for: $0)) }
        XCTAssertEqual(items.map(\.sourceFolder), ["Sent", "Sent", "Receipts"])

        await model.applyMoveRequest(MessageMoveRequest(destination: "Junk", items: items, sourceList: nil, tick: 1))

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"])
        XCTAssertEqual(calls.first?.uids, [4])
        XCTAssertEqual(model.envelopes.map(\.uid), [9, 9])
        XCTAssertEqual(model.selectedUIDs, [9])
        assertLeftUnchangedNotice(model)
    }

    func testSingleRowDragIsNotGuarded() async throws {
        // A one-item drag names the row it lifted, so the guard (which reasons
        // about a bare-UID selection) stays out of it.
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.applyMoveRequest(MessageMoveRequest(
            destination: "Junk", items: [MessageDragItem(uid: 4, sourceFolder: "Receipts")], sourceList: nil, tick: 1
        ))

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"])
        XCTAssertNil(model.skippedNotice)
    }

    // MARK: - The note's lifetime

    func testAnActionWithNothingToSkipSaysNothing() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.setSeen(true, uids: [4])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["Receipts"])
        XCTAssertNil(model.skippedNotice)
    }

    func testTheNextActionReplacesTheNote() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        await model.setSeen(true, uids: [9])
        XCTAssertNotNil(model.skippedNotice)

        await model.setFlagged(true, uids: [4])

        XCTAssertNil(model.skippedNotice, "the note describes the last action, not an earlier one")
    }

    func testRefreshingTheSearchKeepsTheNoteButANewSearchDropsIt() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        await model.setSeen(true, uids: [9])

        // The background pass and pull-to-refresh re-run the same search in place.
        await model.runSearch(resetFilterTab: false, preserveDepth: true)
        XCTAssertNotNil(model.skippedNotice)

        model.searchQuery = "receipt"
        await model.runSearch()
        XCTAssertNil(model.skippedNotice)
    }
}
