import XCTest
import CabalmailKit
@testable import CabalmailUI

// The search surface hears the mail store's events like any list, matched by
// each row's own ref (#1877): archiving, deleting or moving a search result
// from the reader left its row, because the list's observers took only the
// signals that named its folder, and the search surface's folder is a
// sentinel. The selection reactions are applied as the list's view does
// (`ListViewSelection`).
@MainActor
final class MailEventSearchSurfaceTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()
    private let inbox = MessageRef(folder: "INBOX", uid: 525)
    /// The same UID in another folder: another message.
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

    /// The search surface holding `rows` from a submitted search, over
    /// `appState`'s store.
    private func searchModel(
        imap: FakeImapClient,
        appState: AppState,
        rows: [SearchedEnvelope]
    ) async throws -> MessageListViewModel {
        await imap.scriptSearch(searchResult(rows))
        let model = MessageListViewModel(
            scope: .search,
            client: try await fixture.makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: appState.mailStore
        )
        model.searchQuery = "throwaway"
        await model.runSearch()
        return model
    }

    private func searchResult(_ rows: [SearchedEnvelope]) -> SearchResult {
        SearchResult(
            envelopes: rows,
            totalEstimate: rows.count,
            nextCursor: nil,
            foldersSearched: Array(Set(rows.map(\.folder))),
            truncated: false
        )
    }

    /// INBOX 525 (unread), Sent 525 (read) and Archive 7 (unread).
    private var threeResults: [SearchedEnvelope] {
        [
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 525), folder: "INBOX"),
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 525, flags: [.seen]), folder: "Sent"),
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 7), folder: "Archive"),
        ]
    }

    private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
        MessageRef(folder: folder, uid: uid)
    }

    /// The issue's steps through the reader itself: archive the opened
    /// result, then the server refuses.
    func testASearchResultArchivedFromTheReaderLeavesAdvancesAndComesBackOnFailure() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 4, total: 10)
        let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)
        XCTAssertEqual(model.rowRefs, [inbox, sent, archive], "precondition")
        model.selectedRefs = [inbox]
        let view = ListViewSelection(model, in: windowA)
        let reader = try await fixture.makeReader(
            imap: imap, envelope: try XCTUnwrap(model.envelope(for: inbox)), folderPath: "INBOX"
        )
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore, from: windowA)
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        await imap.holdNext(.move)

        let dispose = Task { await reader.dispose() }
        await imap.awaitHeld(.move)

        XCTAssertEqual(model.rowRefs, [sent, archive], "the archived result left; its Sent copy stays")
        view.apply()
        XCTAssertEqual(model.selectedRefs, [archive], "the reading pane moved on to the next unread result")
        XCTAssertEqual(view.shown, archive)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 3, "the archive read it")

        await imap.releaseHeld(.move)
        await dispose.value

        XCTAssertEqual(model.rowRefs, [inbox, sent, archive], "the refused archive put the row back where it was")
        XCTAssertFalse(try XCTUnwrap(model.envelope(for: inbox)).flags.contains(.seen), "unread again")
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 4)
        XCTAssertEqual(model.selectedRefs, [archive], "the selection stays where the advance left it")
    }

    /// Move and Delete Forever post the same removal as Archive.
    func testAMoveOrPurgeFromTheReaderDropsTheSearchRow() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)

        appState.mailStore.events.post(.removed([archive]), from: windowA)
        appState.mailStore.events.post(.removed([sent]), from: windowA)

        XCTAssertEqual(model.rowRefs, [inbox])
    }

    func testAnEventForAMessageTheSearchDoesNotListChangesNothing() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)
        let before = model.envelopes

        appState.mailStore.events.post(.removed([ref(525, in: "Drafts")]), from: windowA)
        appState.mailStore.events.post(.flagsChanged([ref(525, in: "Drafts")], flag: .flagged, added: true), from: nil)

        XCTAssertEqual(model.envelopes, before)
        XCTAssertEqual(model.selectionReactions.since(0), [], "nothing for the selection to do")
    }

    /// Save Draft over a copy the search lists: the copy leaves, the search
    /// re-runs for the survivor, and a reader on the retired copy is
    /// re-pointed at it. The INBOX message that shares the retired UID stays.
    func testADraftReplacedOnTheSearchSurfaceRepointsTheReader() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let retired = ref(610, in: "Drafts")
        let survivor = ref(700, in: "Drafts")
        let model = try await searchModel(imap: imap, appState: appState, rows: [
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 610), folder: "Drafts"),
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 610), folder: "INBOX"),
        ])
        model.selectedRefs = [retired]
        let view = ListViewSelection(model, in: windowA)
        await imap.scriptSearch(searchResult([
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 700), folder: "Drafts"),
            SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 610), folder: "INBOX"),
        ]))
        let ticks = model.selectionReactions.tick

        appState.mailStore.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [610], survivingUID: 700)),
            from: nil
        )
        XCTAssertEqual(model.rowRefs, [ref(610)], "the retired copy left at once; INBOX 610 is another message")
        try await waitUntilOnMainActor { model.selectionReactions.tick > ticks }
        view.apply()

        XCTAssertEqual(model.rowRefs, [survivor, ref(610)])
        XCTAssertEqual(model.selectedRefs, [survivor])
        XCTAssertEqual(view.shown, survivor)
        let searches = await imap.searchCalls.count
        XCTAssertEqual(searches, 2, "the search re-ran once for the survivor")
    }

    /// A draft saved while the results list none of its copies doesn't
    /// re-run the search.
    func testADraftReplacementTheSearchDoesNotListLeavesItAlone() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)

        appState.mailStore.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [525], survivingUID: 700)),
            from: nil
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.rowRefs, [inbox, sent, archive])
        let searches = await imap.searchCalls.count
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(model.selectionReactions.since(0), [])
    }

    // MARK: - One search model, two windows

    /// Every window shows the one search model (`AppState.sharedSearchModel`),
    /// so both windows' lists apply the same reactions, each from its own
    /// place and for its own window, whichever applies first. Two iPad
    /// windows at compact width, each reading the archived result: the one
    /// that archived moves on, the other lets go.
    func testOneSearchModelInTwoCompactWindowsMovesOnlyTheOriginsReader() async throws {
        for windowAFirst in [true, false] {
            let imap = FakeImapClient()
            let appState = AppState()
            let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)
            let inA = ListViewSelection(model, in: windowA, isWideLayout: false, shown: inbox)
            let inB = ListViewSelection(model, in: windowB, isWideLayout: false, shown: inbox)

            appState.mailStore.events.post(.removed([inbox]), from: windowA)
            for view in windowAFirst ? [inA, inB] : [inB, inA] { view.apply() }

            let order = windowAFirst ? "A first" : "B first"
            XCTAssertEqual(inA.shown, archive, "\(order): the window that archived moves on")
            XCTAssertNil(inB.shown, "\(order): the other window lets go of the result")
        }
    }

    /// The same at wide width, where the two windows also share the model's
    /// selected rows: the window that marked read moves on whichever window
    /// applies first.
    func testOneSearchModelInTwoWideWindowsStillAdvancesTheOrigin() async throws {
        for windowAFirst in [true, false] {
            let imap = FakeImapClient()
            let appState = AppState()
            let model = try await searchModel(imap: imap, appState: appState, rows: threeResults)
            model.selectedRefs = [inbox]
            let inA = ListViewSelection(model, in: windowA)
            let inB = ListViewSelection(model, in: windowB)

            appState.mailStore.events.post(.removed([inbox]), from: windowA)
            for view in windowAFirst ? [inA, inB] : [inB, inA] { view.apply() }

            let order = windowAFirst ? "A first" : "B first"
            XCTAssertEqual(inA.shown, archive, order)
            XCTAssertEqual(model.selectedRefs, [archive], order)
        }
    }
}
