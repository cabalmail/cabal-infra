import XCTest
import CabalmailKit
@testable import CabalmailUI

// A search result read in the reader loses its unread dot (#1859). The global
// search surface's `folder` is a sentinel (path ""), and its rows come from
// many folders, so the list's flag observer, which took only the signals that
// named its own folder, dropped every one of them there: the row kept its dot
// until the next search. The observer now hands the signal to
// `applyReaderFlagChange`, which on the search surface matches it by the row's
// ref. Every signal here is sent the way the reader sends it, through
// `MailSessionStore.signalFlagChange` (or the reader itself, wired by
// `MessageDetailView.relayOutcomes`), and handed to the list as its observer
// does.
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

    /// Hands the latest flag signal to `model`, as the list's `.onChange`
    /// observer does.
    private func deliver(_ appState: AppState, to model: MessageListViewModel) throws {
        let signal = appState.mailStore.signals.lastEnvelopeFlagChange
        model.applyReaderFlagChange(try XCTUnwrap(signal, "the reader sent a signal"))
    }

    func testReadingAResultClearsItsUnreadDot() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)

        appState.mailStore.signalFlagChange(inbox, flag: .seen, added: true)
        try deliver(appState, to: model)

        XCTAssertFalse(try isUnread(inbox, in: model), "the result the reader opened is read")
        XCTAssertTrue(try isUnread(sent, in: model), "the same UID in Sent is another message")
        XCTAssertTrue(try isUnread(archive, in: model))
    }

    func testMarkingAResultUnreadPutsTheDotBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)

        appState.mailStore.signalFlagChange(archive, flag: .seen, added: true)
        try deliver(appState, to: model)
        XCTAssertFalse(try isUnread(archive, in: model))

        appState.mailStore.signalFlagChange(archive, flag: .seen, added: false)
        try deliver(appState, to: model)
        XCTAssertTrue(try isUnread(archive, in: model), "the reader's Mark as Unread reaches the row too")
    }

    func testASignalForAMessageTheSearchDoesNotListChangesNothing() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState)
        let before = model.envelopes

        appState.mailStore.signalFlagChange(MessageRef(folder: "Drafts", uid: 525), flag: .seen, added: true)
        try deliver(appState, to: model)

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
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)

        await reader.load()
        try await waitUntil { await !imap.flagCalls.isEmpty }
        try await waitUntilOnMainActor { appState.mailStore.signals.lastEnvelopeFlagChange != nil }
        try deliver(appState, to: model)

        XCTAssertEqual(appState.mailStore.signals.lastEnvelopeFlagChange?.ref, inbox)
        XCTAssertFalse(try isUnread(inbox, in: model), "back on the results, the opened row is read")
        XCTAssertTrue(try isUnread(sent, in: model))
    }

    /// A folder list still takes only its own folder's signals.
    func testAFolderListTakesOnlyItsOwnFoldersSignals() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 525)],
            folderPath: "INBOX",
            mailStore: appState.mailStore
        )

        appState.mailStore.signalFlagChange(sent, flag: .seen, added: true)
        try deliver(appState, to: model)
        XCTAssertTrue(try isUnread(inbox, in: model), "Sent's UID 525 is not this row")

        appState.mailStore.signalFlagChange(inbox, flag: .seen, added: true)
        try deliver(appState, to: model)
        XCTAssertFalse(try isUnread(inbox, in: model))
    }
}
