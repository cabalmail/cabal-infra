import XCTest
import CabalmailKit
@testable import CabalmailUI

// One message filed in two folders under the same UID: mail you send
// yourself lands in INBOX and in Sent with one Message-ID, and in a small
// mailbox the two UIDs can coincide. Nothing in the envelope tells the
// copies apart -- the API path gives both the same Date-derived
// internalDate and a nil size -- so the rows below are identical except
// that the Sent copy is read, exactly as a cross-folder search returns
// them. The server sorts the Sent copy first.
//
// The wire does tell them apart, by each row's folder, and every row keeps
// it (`MessageRef`). So each copy is selected, acted on, dragged and
// re-delivered as itself: acting on the INBOX copy changes only INBOX, and
// the Sent copy is the negative control throughout. Before MessageRef both
// rows resolved to Sent, and a guard (#1790) left them alone instead.
@MainActor
final class SelfSentSearchCopyTests: XCTestCase {
    private let messageID = "<note-to-self@example.com>"
    private let sent = MessageRef(folder: "Sent", uid: 9)
    private let inbox = MessageRef(folder: "INBOX", uid: 9)
    private let receipt = MessageRef(folder: "Receipts", uid: 4)

    private func sentCopy() -> Envelope {
        TestFixtures.makeEnvelope(uid: 9, flags: [.seen], messageId: messageID, subject: "note to self")
    }

    private func inboxCopy() -> Envelope {
        TestFixtures.makeEnvelope(uid: 9, messageId: messageID, subject: "note to self")
    }

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

    private func row(_ ref: MessageRef, in model: MessageListViewModel) throws -> Envelope {
        try XCTUnwrap(model.envelope(for: ref), "\(ref) is listed")
    }

    private func listed(_ model: MessageListViewModel) -> [MessageRef] {
        model.envelopes.map { model.rowRef(for: $0) }
    }

    // MARK: - Each copy is its own row

    func testTheTwoCopiesAreTwoRows() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        XCTAssertEqual(listed(model), [sent, inbox, receipt])
        XCTAssertTrue(try row(sent, in: model).flags.contains(.seen))
        XCTAssertFalse(try row(inbox, in: model).flags.contains(.seen), "each ref resolves to its own row")
    }

    func testSelectingOneCopySelectsOnlyIt() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        model.toggleSelection(try row(inbox, in: model))

        XCTAssertEqual(model.selectedRefs, [inbox])
        XCTAssertEqual(model.envelope(for: inbox)?.flags.contains(.seen), false,
                       "the wide reader opens the copy that was picked, not the first one listed")
    }

    // MARK: - Bulk actions

    func testMarkingUnreadReachesOnlyTheChosenCopy() async throws {
        // The soak's repro: Mark Unread on a selection holding one copy
        // changed the other copy instead.
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.setSeen(false, refs: [sent, receipt])

        let calls = await imap.flagCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["Sent", "Receipts"], "nothing is written to INBOX")
        XCTAssertEqual(calls.first { $0.folder == "Sent" }?.uids, [9])
        XCTAssertTrue(calls.allSatisfy { $0.operation == .remove })
        XCTAssertFalse(try row(sent, in: model).flags.contains(.seen), "the Sent copy is now unread")
        XCTAssertNil(model.errorMessage)
    }

    func testBulkFlagReachesOnlyTheChosenCopy() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.setFlagged(true, refs: [inbox])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["INBOX"])
        XCTAssertEqual(calls.first?.uids, [9])
        XCTAssertTrue(try row(inbox, in: model).flags.contains(.flagged))
        XCTAssertFalse(try row(sent, in: model).flags.contains(.flagged), "the Sent copy is not flagged")
    }

    func testBulkMoveMovesOnlyTheChosenCopy() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        model.selectedRefs = [inbox, receipt]

        await model.moveMessages(refs: [inbox, receipt], to: "Junk")

        let calls = await imap.moveCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["INBOX", "Receipts"])
        XCTAssertEqual(calls.first { $0.folder == "INBOX" }?.uids, [9])
        XCTAssertEqual(listed(model), [sent], "the Sent copy stays listed")
        XCTAssertEqual(model.selectedRefs, [], "the moved rows leave the selection and nothing else was in it")
    }

    func testBulkArchiveArchivesOnlyTheChosenCopy() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        await model.disposeMessages(refs: [sent], action: .archive)

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Sent"])
        XCTAssertEqual(calls.first?.uids, [9])
        XCTAssertEqual(calls.first?.destination, "Archive")
        XCTAssertEqual(listed(model), [inbox, receipt], "the INBOX copy stays listed")
    }

    func testACopyOnASecondPageIsItsOwnRow() async throws {
        // INBOX copy on page 1, Sent copy on page 2.
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
        await model.search.loadMore()
        XCTAssertEqual(model.envelopes.count, 51, "the copy from Sent is a new row, not a repeat of INBOX's")

        await model.setFlagged(true, refs: [sent])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["Sent"])
        XCTAssertFalse(try row(inbox, in: model).flags.contains(.flagged))
    }

    // MARK: - A page boundary re-delivering a row

    func testACopyReDeliveredByTheNextPageIsNotAppendedTwice() async throws {
        let imap = FakeImapClient()
        let fillers = (100..<148).map {
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: UInt32($0)), folder: "INBOX")
        }
        await imap.scriptSearchPages([
            SearchResult(
                envelopes: [
                    SearchedEnvelope(envelope: sentCopy(), folder: "Sent"),
                    SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
                ] + fillers,
                totalEstimate: 51, nextCursor: "c1", foldersSearched: ["INBOX", "Sent"], truncated: false
            ),
            // The date cursor shifted: page 2 starts by re-delivering the
            // INBOX copy, then brings one new row.
            SearchResult(
                envelopes: [
                    SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
                    SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 4), folder: "Receipts"),
                ],
                totalEstimate: 51, nextCursor: nil, foldersSearched: ["INBOX", "Sent"], truncated: false
            ),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "note"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.count, 50)

        await model.search.loadMore()

        XCTAssertEqual(model.envelopes.count, 51, "only the new Receipts row is appended")
        XCTAssertEqual(listed(model).filter { $0 == inbox }.count, 1)
        XCTAssertEqual(listed(model).filter { $0 == sent }.count, 1)
    }

    func testARowReDeliveredInsideOneChunkedWalkIsOneRow() async throws {
        // An in-place refresh re-walks every page already loaded in one
        // chunked call; a boundary inside that walk can deliver a row twice.
        let imap = FakeImapClient()
        let firstPage = [
            SearchedEnvelope(envelope: sentCopy(), folder: "Sent"),
            SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
        ] + (100..<148).map {
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: UInt32($0)), folder: "INBOX")
        }
        await imap.scriptSearchPages([
            SearchResult(envelopes: firstPage, totalEstimate: 51, nextCursor: "c1",
                         foldersSearched: ["INBOX", "Sent"], truncated: false),
            SearchResult(envelopes: [SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 4), folder: "Receipts")],
                         totalEstimate: 51, nextCursor: nil, foldersSearched: ["INBOX", "Sent"], truncated: false),
            // The refresh's walk: page 1, then a page 2 that repeats the
            // INBOX copy before the Receipts row.
            SearchResult(envelopes: firstPage, totalEstimate: 51, nextCursor: "c1",
                         foldersSearched: ["INBOX", "Sent"], truncated: false),
            SearchResult(
                envelopes: [
                    SearchedEnvelope(envelope: inboxCopy(), folder: "INBOX"),
                    SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 4), folder: "Receipts"),
                ],
                totalEstimate: 51, nextCursor: nil, foldersSearched: ["INBOX", "Sent"], truncated: false
            ),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "note"
        await model.runSearch()
        await model.search.loadMore()
        XCTAssertEqual(model.envelopes.count, 51)

        await model.runSearch(resetFilterTab: false, preserveDepth: true, rerun: true)

        XCTAssertEqual(model.envelopes.count, 51, "the repeated INBOX copy is dropped from the re-walk")
        XCTAssertEqual(listed(model).filter { $0 == inbox }.count, 1)
        XCTAssertEqual(Set(listed(model)).count, listed(model).count, "every row is its own message")
    }

    // MARK: - Dragging

    func testASelectionDragCarriesEachRowsOwnFolder() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        model.selectedRefs = [inbox, receipt]

        let items = model.dragItems(liftedFrom: try row(inbox, in: model))
        XCTAssertEqual(items.map(\.ref), [inbox, receipt], "the INBOX copy is dragged from INBOX")

        await model.applyMoveRequest(MessageMoveRequest(destination: "Junk", items: items, sourceList: nil, tick: 1))

        let calls = await imap.moveCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["INBOX", "Receipts"])
        XCTAssertEqual(listed(model), [sent], "the Sent copy stays put")
        XCTAssertEqual(model.selectedRefs, [])
    }

    func testASingleRowDragLiftsOnlyThatCopy() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)

        let items = model.dragItems(liftedFrom: try row(sent, in: model))
        XCTAssertEqual(items, [MessageDragItem(uid: 9, sourceFolder: "Sent")])

        await model.applyMoveRequest(MessageMoveRequest(destination: "Junk", items: items, sourceList: nil, tick: 1))

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["Sent"])
        XCTAssertEqual(calls.first?.uids, [9])
        XCTAssertEqual(listed(model), [inbox, receipt], "the INBOX copy, sharing the UID, is neither moved nor dropped")
    }

    func testDraggingAnUnselectedRowLiftsOnlyThatRow() async throws {
        let imap = FakeImapClient()
        let model = try await selfSentSearchModel(imap: imap)
        model.selectedRefs = [sent, receipt]

        let items = model.dragItems(liftedFrom: try row(inbox, in: model))

        XCTAssertEqual(items.map(\.ref), [inbox], "the INBOX copy is not part of the selection, whatever its UID")
    }
}
