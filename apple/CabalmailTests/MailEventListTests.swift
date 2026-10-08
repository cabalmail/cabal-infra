import XCTest
import CabalmailKit
@testable import CabalmailUI

// A message list hears the mail store's events for its model's whole life and
// matches each against its own rows by ref (`MessageListViewModel.receive`).
// #1845 (items 1 and 2): with two windows, a reader's archive or
// mark-read-and-advance moved the selection in every window, because the
// signals named none. These tests post the way the reader and the composer
// post, and apply the selection reactions as the list's view does
// (`ListViewSelection`). The search surface's half is
// `MailEventSearchSurfaceTests`.
@MainActor
final class MailEventListTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()
    private let inbox = MessageRef(folder: "INBOX", uid: 525)
    /// The same UID in another folder: another message.
    private let sent = MessageRef(folder: "Sent", uid: 525)

    private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
        MessageRef(folder: folder, uid: uid)
    }

    // MARK: - The Drafts folder

    /// Save Draft over the copy a Drafts list's reader shows: the copy
    /// leaves at once, the list refreshes for the survivor, and the reader
    /// is re-pointed at it (#1078) -- now from the model, which hears the
    /// event for its whole life, rather than from the view.
    func testADraftReplacedInTheDraftsListRepointsTheReaderAtTheSurvivor() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let drafts = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 610), TestFixtures.makeEnvelope(uid: 639)],
            folderPath: "Drafts",
            mailStore: appState.mailStore
        )
        drafts.selectedRefs = [ref(610, in: "Drafts")]
        let view = ListViewSelection(drafts, in: windowA)
        await imap.scriptInitialLoad(
            status: FolderStatus(messages: 2, unseen: 0, flagged: 0, uidValidity: 7, uidNext: 701),
            topEnvelopes: [TestFixtures.makeEnvelope(uid: 700), TestFixtures.makeEnvelope(uid: 639)]
        )
        let ticks = drafts.selectionReactions.tick

        appState.mailStore.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [610], survivingUID: 700)),
            from: nil
        )
        XCTAssertEqual(drafts.rowRefs, [ref(639, in: "Drafts")], "the retired copy left at once")
        try await waitUntilOnMainActor { drafts.selectionReactions.tick > ticks }
        view.apply()

        XCTAssertEqual(Set(drafts.rowRefs), [ref(700, in: "Drafts"), ref(639, in: "Drafts")])
        XCTAssertEqual(drafts.selectedRefs, [ref(700, in: "Drafts")])
        XCTAssertEqual(view.shown, ref(700, in: "Drafts"))
    }

    /// Another folder's list neither prunes nor refreshes for a Drafts save.
    func testADraftReplacementLeavesAnotherFoldersListAlone() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try TestFixtures.makeModel(
            imap: imap, envelopes: [TestFixtures.makeEnvelope(uid: 610)], mailStore: appState.mailStore
        )

        appState.mailStore.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [610], survivingUID: 700)),
            from: nil
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(list.rowRefs, [ref(610)])
        let statusCalls = await imap.statusCalls.count
        XCTAssertEqual(statusCalls, 0, "no refresh")
        XCTAssertEqual(list.selectionReactions.since(0), [])
    }

    // MARK: - Two windows (#1845)

    /// Two INBOX lists, one per window, both showing UID 3 of 5, 4, 3, 2, 1
    /// (4 and 2 unread).
    private func twoWindows(_ appState: AppState) throws -> (MessageListViewModel, MessageListViewModel) {
        let envelopes = [5, 4, 3, 2, 1].map {
            TestFixtures.makeEnvelope(uid: UInt32($0), flags: [4, 2].contains($0) ? [] : [.seen])
        }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: FakeImapClient(), envelopes: envelopes, mailStore: store)
        let second = try TestFixtures.makeModel(imap: FakeImapClient(), envelopes: envelopes, mailStore: store)
        first.selectedRefs = [ref(3)]
        second.selectedRefs = [ref(3)]
        return (first, second)
    }

    func testAReaderArchiveAdvancesOnlyItsOwnWindowWhileBothListsDropTheRow() throws {
        let appState = AppState()
        let (inA, inB) = try twoWindows(appState)
        let viewA = ListViewSelection(inA, in: windowA)
        let viewB = ListViewSelection(inB, in: windowB)

        appState.mailStore.events.post(.removed([ref(3)]), from: windowA)
        viewA.apply()
        viewB.apply()

        XCTAssertEqual(inA.rowRefs, [ref(5), ref(4), ref(2), ref(1)])
        XCTAssertEqual(inB.rowRefs, [ref(5), ref(4), ref(2), ref(1)])
        XCTAssertEqual(inA.selectedRefs, [ref(2)], "the window that archived goes on to the next unread")
        XCTAssertEqual(viewA.shown, ref(2))
        XCTAssertEqual(inB.selectedRefs, [], "the other window lets go of the row without advancing")
        XCTAssertNil(viewB.shown)
    }

    func testAReadAdvanceMovesOnlyItsOwnWindow() throws {
        let appState = AppState()
        let (inA, inB) = try twoWindows(appState)
        let viewA = ListViewSelection(inA, in: windowA)
        let viewB = ListViewSelection(inB, in: windowB)

        appState.mailStore.events.post(.readAdvance(ref(3), advance: .nextUnread), from: windowA)
        viewA.apply()
        viewB.apply()

        XCTAssertEqual(inA.selectedRefs, [ref(2)])
        XCTAssertEqual(viewA.shown, ref(2))
        XCTAssertEqual(inB.selectedRefs, [ref(3)], "the other window's reader stays on the message")
        XCTAssertEqual(viewB.shown, ref(3))
        XCTAssertEqual(inA.rowRefs.count, 5, "a read advance prunes nothing")
        XCTAssertEqual(inB.rowRefs.count, 5)
    }

    /// A send from a compose window names no window: each window whose
    /// selection is on the copy advances, as before.
    func testARemovalNoWindowStartedAdvancesEveryWindowOnTheRow() throws {
        let appState = AppState()
        let (inA, inB) = try twoWindows(appState)
        inB.selectedRefs = [ref(5)]
        let viewA = ListViewSelection(inA, in: windowA)
        let viewB = ListViewSelection(inB, in: windowB)

        appState.mailStore.events.post(.removed([ref(3)]), from: nil)
        viewA.apply()
        viewB.apply()

        XCTAssertEqual(inA.selectedRefs, [ref(2)])
        XCTAssertEqual(inB.selectedRefs, [ref(5)], "a selection elsewhere doesn't move")
    }

    /// A wide list with no selected rows under an open reader (rebuilt when
    /// a search ended, or carried over from a compact window) still moves
    /// its reader on: the reader's own message is its selection.
    func testAWideListWithNoSelectedRowsFollowsItsReader() throws {
        let appState = AppState()
        let (inA, _) = try twoWindows(appState)
        inA.selectedRefs = []
        let viewA = ListViewSelection(inA, in: windowA, shown: ref(3))

        appState.mailStore.events.post(.removed([ref(3)]), from: windowA)
        viewA.apply()

        XCTAssertEqual(inA.selectedRefs, [ref(2)])
        XCTAssertEqual(viewA.shown, ref(2))
    }

    // MARK: - Delivery

    /// The signals kept their latest value only, so the first of two
    /// removals in one update never reached the list. Both layouts end on
    /// the second advance's target, though the first target was pruned by
    /// the second removal before the view applied either.
    func testTwoEventsInOneTurnBothApply() throws {
        for isWideLayout in [true, false] {
            let appState = AppState()
            let envelopes = [5, 4, 3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: [.seen]) }
            let list = try TestFixtures.makeModel(
                imap: FakeImapClient(), envelopes: envelopes, mailStore: appState.mailStore
            )
            list.preferences.disposeAdvance = .next
            if isWideLayout { list.selectedRefs = [ref(4)] }
            let view = ListViewSelection(list, in: windowA, isWideLayout: isWideLayout, shown: ref(4))

            appState.mailStore.events.post(.removed([ref(4)]), from: windowA)
            appState.mailStore.events.post(.removed([ref(3)]), from: windowA)
            view.apply()

            let layout = isWideLayout ? "wide" : "compact"
            XCTAssertEqual(list.rowRefs, [ref(5), ref(2), ref(1)], layout)
            XCTAssertEqual(view.shown, ref(2), "\(layout): both advances applied, in order")
            XCTAssertEqual(list.selectedRefs, isWideLayout ? [ref(2)] : [], layout)
        }
    }

    /// On iPhone the list under a pushed reader has had `.onDisappear`; only
    /// its model is left to hear the archive.
    func testAListWhoseViewIsGoneStillDropsTheRow() throws {
        let appState = AppState()
        let list = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 2), TestFixtures.makeEnvelope(uid: 1)],
            mailStore: appState.mailStore
        )

        appState.mailStore.events.post(.removed([ref(2)]), from: windowA)

        XCTAssertEqual(list.rowRefs, [ref(1)])
    }

    func testTheStoreDoesNotKeepAListAlive() throws {
        let appState = AppState()
        var list: MessageListViewModel? = try TestFixtures.makeModel(
            imap: FakeImapClient(), envelopes: [TestFixtures.makeEnvelope(uid: 1)], mailStore: appState.mailStore
        )
        weak var gone = list

        list = nil
        appState.mailStore.events.post(.removed([ref(1)]), from: nil)

        XCTAssertNil(gone)
    }

    /// A folder list takes its own folder's refs only: the same UID in
    /// another folder is another message.
    func testAFolderListTakesOnlyItsOwnFoldersRows() throws {
        let appState = AppState()
        let list = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 525), TestFixtures.makeEnvelope(uid: 1)],
            mailStore: appState.mailStore
        )

        appState.mailStore.events.post(.removed([sent]), from: windowA)
        appState.mailStore.events.post(.flagsChanged([sent], flag: .seen, added: true), from: windowA)
        XCTAssertEqual(list.rowRefs, [inbox, ref(1)])
        XCTAssertFalse(try XCTUnwrap(list.envelope(for: inbox)).flags.contains(.seen))

        appState.mailStore.events.post(.flagsChanged([inbox], flag: .seen, added: true), from: windowA)
        XCTAssertTrue(try XCTUnwrap(list.envelope(for: inbox)).flags.contains(.seen))
        appState.mailStore.events.post(.removed([inbox]), from: windowA)
        XCTAssertEqual(list.rowRefs, [ref(1)])
    }

    /// A reader open on a message the list hasn't loaded (its window moved
    /// on) still lets go of it when the message is archived, as before.
    func testARemovalOfARowTheListNeverLoadedClearsASelectionOnIt() throws {
        let appState = AppState()
        let list = try TestFixtures.makeModel(
            imap: FakeImapClient(), envelopes: [TestFixtures.makeEnvelope(uid: 1)], mailStore: appState.mailStore
        )
        list.selectedRefs = [ref(900)]
        let view = ListViewSelection(list, in: windowA)

        appState.mailStore.events.post(.removed([ref(900)]), from: windowA)
        view.apply()

        XCTAssertEqual(list.selectedRefs, [])
        XCTAssertNil(view.shown)
        XCTAssertEqual(list.rowRefs, [ref(1)])
    }
}
