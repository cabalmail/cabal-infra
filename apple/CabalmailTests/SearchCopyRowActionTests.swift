import XCTest
import CabalmailKit
@testable import CabalmailUI

// Every single-row path on a cross-folder search row whose UID another row
// shares (#1791): swipe, the row menu, the reader (compact and wide),
// mark-read-on-open, the reader toolbar and a range selection. The rows are
// one message filed twice under one UID -- mail you send yourself, in Sent
// and INBOX -- because nothing in their envelopes tells them apart: before
// rows carried their folder, each of these acted on the first copy listed
// (Sent) whichever row the user touched. Each test acts on the INBOX copy
// and holds the Sent copy as the negative control.
@MainActor
final class SearchCopyRowActionTests: XCTestCase {
    private let sent = MessageRef(folder: "Sent", uid: 9)
    private let inbox = MessageRef(folder: "INBOX", uid: 9)
    private let receipt = MessageRef(folder: "Receipts", uid: 4)
    private let messageID = "<note-to-self@example.com>"

    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func searchModel(imap: FakeImapClient) async throws -> MessageListViewModel {
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(
                    envelope: TestFixtures.makeEnvelope(uid: 9, flags: [.seen], messageId: messageID),
                    folder: "Sent"
                ),
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 9, messageId: messageID), folder: "INBOX"),
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 4), folder: "Receipts"),
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

    // MARK: - Swipe and row menu

    func testSwipingOneCopyDisposesOnlyIt() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        let target = try row(inbox, in: model)

        let disposal = Task { await model.dispose(target) }
        try await waitUntil { await model.rowDisposalPhases[self.inbox] != nil }
        XCTAssertNil(model.rowDisposalPhases[sent], "only the swiped row fades")
        await disposal.value

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["INBOX"])
        XCTAssertEqual(calls.first?.uids, [9])
        XCTAssertEqual(listed(model), [sent, receipt], "the Sent copy stays listed")
    }

    func testASecondSwipeOnTheOtherCopyIsNotSwallowed() async throws {
        // While one copy's dispose is in flight the other copy is a different
        // message: its swipe goes through rather than reading as a repeat.
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        let target = try row(inbox, in: model)
        let first = Task { await model.dispose(target) }
        try await waitUntil { await model.pendingRemovedRefs.contains(self.inbox) }

        await model.dispose(try row(sent, in: model))
        await first.value

        let calls = await imap.moveCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["INBOX", "Sent"])
        XCTAssertEqual(listed(model), [receipt])
    }

    func testTheRowMenusReadAndFlagReachOnlyTheirCopy() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)

        await model.toggleSeen(try row(inbox, in: model))
        await model.toggleFlag(try row(inbox, in: model))

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["INBOX", "INBOX"])
        XCTAssertTrue(try row(inbox, in: model).flags.isSuperset(of: [.seen, .flagged]))
        XCTAssertFalse(try row(sent, in: model).flags.contains(.flagged), "the Sent copy's row does not flip")
    }

    func testTheRowMenusMoveReachesOnlyItsCopyAndThePickerHidesItsFolder() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        let target = try row(inbox, in: model)
        // What the move picker hides (`MessageListView.moveSheet`).
        XCTAssertEqual(model.rowRef(for: target).folder, "INBOX")

        await model.moveTo(target, destination: "Sent")

        let calls = await imap.moveCalls
        XCTAssertEqual(calls.map(\.folder), ["INBOX"])
        XCTAssertEqual(calls.first?.destination, "Sent")
        XCTAssertEqual(listed(model), [sent, receipt])
    }

    // MARK: - Selection

    func testSelectingOneCopyHighlightsOnlyThatRow() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)

        model.toggleSelection(try row(inbox, in: model))

        XCTAssertTrue(model.isSelected(try row(inbox, in: model)))
        XCTAssertFalse(model.isSelected(try row(sent, in: model)), "the Sent copy shares the UID; it stays plain")
        XCTAssertEqual(model.selectedRefs.count, 1, "the bar counts one message")
    }

    func testMarkingOneCopyReadMovesOnlyItsFoldersBadge() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        model.appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 3, total: 10)
        model.appState.mailStore.counts.setFolderCounts(folderPath: "Sent", unread: 2, total: 10)

        await model.setSeen(true, refs: [inbox])

        XCTAssertEqual(model.appState.mailStore.counts.folderUnreadCounts["INBOX"], 2)
        XCTAssertEqual(
            model.appState.mailStore.counts.folderUnreadCounts["Sent"], 2,
            "Sent's copy was already read and is not touched"
        )
        XCTAssertTrue(try row(inbox, in: model).flags.contains(.seen))
    }

    func testARangeFromTheSecondCopySpansFromIt() {
        // Shift-click from the INBOX copy down to Receipts: the span starts
        // at the copy the anchor names, not at the first row with its UID.
        let outcome = RangeSelectionPolicy.outcome(
            base: [inbox], anchor: inbox, target: receipt, ordered: [sent, inbox, receipt]
        )
        XCTAssertEqual(outcome.selected, [inbox, receipt])
    }

    func testDisposingASelectionThatStaysInEditModeLeavesNothingSelected() async throws {
        // #1792: Cmd+Delete and the context menu's Archive keep edit mode; a
        // colliding UID the old guard skipped stayed selected and opened a
        // row the user never picked. Both copies go, and nothing is left to
        // derive a reader selection from.
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        model.selectedRefs = [sent, inbox]

        await model.disposeMessages(refs: model.selectedRefs, action: .trash)

        let calls = await imap.moveCalls
        XCTAssertEqual(Set(calls.map(\.folder)), ["Sent", "INBOX"])
        XCTAssertEqual(model.selectedRefs, [])
        XCTAssertEqual(listed(model), [receipt])
    }

    // MARK: - The reader

    func testTheReaderOpensAgainstTheRowsOwnFolder() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        let inboxFolder = Folder(path: "INBOX", attributes: [], isSubscribed: true)
        // The sidebar shows INBOX while the user opens the Sent copy: the
        // reader (and the row's move picker) take the row's folder.
        XCTAssertEqual(MessageFolderPolicy.folder(for: try row(sent, in: model), in: inboxFolder)?.path, "Sent")

        // Wide: one selected ref resolves to its own row.
        model.selectedRefs = [inbox]
        let selected = try XCTUnwrap(model.selectedRefs.first.flatMap(model.envelope(for:)))
        XCTAssertEqual(selected.folder, "INBOX")
        XCTAssertFalse(selected.flags.contains(.seen), "the unread INBOX copy, not the read Sent copy")
        XCTAssertEqual(MessageFolderPolicy.folder(for: selected, in: nil)?.path, "INBOX")
        XCTAssertEqual(
            MessageFolderPolicy.folder(for: selected, in: inboxFolder), inboxFolder,
            "the sidebar's Folder value is kept when the row is its folder's"
        )
        // Compact (`SearchView`): the row's own ref.
        XCTAssertEqual(model.rowRef(for: try row(sent, in: model)).folder, "Sent")
        // A row with no folder of its own is the sidebar's.
        XCTAssertEqual(MessageFolderPolicy.folder(for: TestFixtures.makeEnvelope(uid: 3), in: inboxFolder),
                       inboxFolder)
    }

    func testMarkReadOnOpenAndTheToolbarReachTheOpenedCopy() async throws {
        let imap = FakeImapClient()
        let model = try await searchModel(imap: imap)
        let copy = try row(inbox, in: model)
        // Opened while the sidebar shows Sent, the copy that shares the UID.
        let sentFolder = Folder(path: "Sent", attributes: [], isSubscribed: true)
        let folder = try XCTUnwrap(MessageFolderPolicy.folder(for: copy, in: sentFolder))
        XCTAssertEqual(folder.path, "INBOX")
        await imap.scriptBody(folder: "INBOX", uid: 9, [.success(MessageDetailMimeFixture.alternative)])
        let reader = try await fixture.makeReader(imap: imap, envelope: copy, folderPath: folder.path,
                                                  markAsRead: .onOpen)
        try await fixture.seedSnapshot(reader)
        let appState = AppState()
        MessageDetailView.relayOutcomes(of: reader, to: appState)

        await reader.load()
        try await waitUntil { await !imap.flagCalls.isEmpty }
        await reader.toggleFlagged()

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.folder), ["INBOX", "INBOX"], "mark-read-on-open, then the toolbar's Flag")
        XCTAssertEqual(calls.map(\.uids), [[9], [9]])
        XCTAssertEqual(reader.ref, inbox)
        XCTAssertEqual(
            appState.mailStore.signals.lastEnvelopeFlagChange?.ref, inbox, "the list is told about the INBOX copy"
        )
    }
}
