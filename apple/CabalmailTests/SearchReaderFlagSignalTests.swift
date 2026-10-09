import XCTest
import CabalmailKit
@testable import CabalmailUI

// A search result read in the reader loses its unread dot (#1859). The global
// search surface's `folder` was a sentinel (path ""), and its rows come from
// many folders, so the list's flag observer, which took only the signals that
// named its own folder, dropped every one of them there: the row kept its dot
// until the next search. The list now hears the store's mail events itself
// (`MessageListViewModel.receive`) and matches each flag change by the row's
// ref. Every change here is the event the reader's write posts on the
// store (`MailMutationService.setFlag`), or the reader itself, wired by
// `MessageDetailView.relayOutcomes`; nothing hands it to the list.
@MainActor
final class SearchReaderFlagSignalTests: XCTestCase {
    private let inbox = MessageRef(folder: "INBOX", uid: 525)
    /// The same UID in another folder: the copy a folder-only match can't
    /// tell apart from `inbox` by UID alone.
    private let sent = MessageRef(folder: "Sent", uid: 525)
    private let archive = MessageRef(folder: "Archive", uid: 7)

    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// The search surface holding three unread results: INBOX 525, Sent 525
    /// and Archive 7.
    private func searchModel(imap: FakeImapClient, appState: AppState) async throws -> MessageListViewModel {
        await imap.scriptSearch(SearchResult(
            envelopes: [
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 525), folder: "INBOX"),
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 525), folder: "Sent"),
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 7), folder: "Archive"),
            ],
            totalEstimate: 3,
            nextCursor: nil,
            foldersSearched: ["INBOX", "Sent", "Archive"],
            truncated: false
        ))
        let client = try await fixture.makeClient(imap: imap)
        let model = MessageListViewModel(
            scope: .search,
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
        model.searchQuery = "throwaway"
        await model.runSearch()
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [inbox, sent, archive])
        return model
    }

    private func isUnread(_ ref: MessageRef, in model: MessageListViewModel) throws -> Bool {
        !(try XCTUnwrap(model.envelope(for: ref), "\(ref) is listed")).flags.contains(.seen)
    }

    func testReadingAResultClearsItsUnreadDot() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)

        appState.mailStore.events.post(.flagsChanged([inbox], flag: .seen, added: true), from: nil)

        XCTAssertFalse(try isUnread(inbox, in: model), "the result the reader opened is read")
        XCTAssertTrue(try isUnread(sent, in: model), "the same UID in Sent is another message")
        XCTAssertTrue(try isUnread(archive, in: model))
    }

    func testMarkingAResultUnreadPutsTheDotBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)

        appState.mailStore.events.post(.flagsChanged([archive], flag: .seen, added: true), from: nil)
        XCTAssertFalse(try isUnread(archive, in: model))

        appState.mailStore.events.post(.flagsChanged([archive], flag: .seen, added: false), from: nil)
        XCTAssertTrue(try isUnread(archive, in: model), "the reader's Mark as Unread reaches the row too")
    }

    func testAChangeToAMessageTheSearchDoesNotListChangesNothing() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)
        let before = model.envelopes
        let events = MailEventRecorder(appState.mailStore)

        appState.mailStore.events.post(
            .flagsChanged([MessageRef(folder: "Drafts", uid: 525)], flag: .seen, added: true), from: nil
        )

        XCTAssertEqual(events.changes.count, 1, "precondition: the change was posted")
        XCTAssertEqual(model.envelopes, before)
    }

    /// The issue's own steps: open an unread result with mark-read-on-open,
    /// let the reader load, go back to the results.
    func testOpeningAnUnreadResultClearsItsDot() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)
        let result = try XCTUnwrap(model.envelope(for: inbox))
        let folder = try XCTUnwrap(MessageFolderPolicy.folder(for: result, in: nil))
        await imap.scriptBody(folder: "INBOX", uid: 525, [.success(MessageDetailMimeFixture.alternative)])
        let reader = try await fixture.makeReader(
            imap: imap, envelope: result, folderPath: folder.path, markAsRead: .onOpen
        )
        try await fixture.seedSnapshot(reader)
        let events = MailEventRecorder(appState.mailStore)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)

        await reader.load()
        try await waitUntil { await !imap.flagCalls.isEmpty }
        try await waitUntilOnMainActor { !events.flagChangeRefs.isEmpty }

        XCTAssertEqual(events.flagChangeRefs, [[inbox]])
        XCTAssertFalse(try isUnread(inbox, in: model), "back on the results, the opened row is read")
        XCTAssertTrue(try isUnread(sent, in: model))
    }

    /// A folder list still takes only its own folder's changes.
    func testAFolderListTakesOnlyItsOwnFoldersChanges() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 525)],
            folderPath: "INBOX",
            mailStore: appState.mailStore
        )

        appState.mailStore.events.post(.flagsChanged([sent], flag: .seen, added: true), from: nil)
        XCTAssertTrue(try isUnread(inbox, in: model), "Sent's UID 525 is not this row")

        appState.mailStore.events.post(.flagsChanged([inbox], flag: .seen, added: true), from: nil)
        XCTAssertFalse(try isUnread(inbox, in: model))
    }
}
