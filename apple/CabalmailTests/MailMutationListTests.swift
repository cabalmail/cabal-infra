import XCTest
import CabalmailKit
@testable import CabalmailUI

// What the mutation service changes for the user: a write made in one list
// reaches every other list and reader at once, instead of at the other
// list's next refresh; a bulk mark-read moves the sidebar count at once and
// puts it back if refused; a removal from global search clears the message
// from its folder's offline copy (#1869); and a reader's move carries the
// unread count. Two lists over one store stand in for two windows, their
// selections applied as each view does (`ListViewSelection`).
@MainActor
final class MailMutationListTests: XCTestCase {
    private let work = "Work"
    private let windowA = UUID()
    private let windowB = UUID()
    private static let refused = CabalmailError.server(code: "500", message: "refused")
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func ref(_ uid: UInt32, in folder: String? = nil) -> MessageRef {
        MessageRef(folder: folder ?? work, uid: uid)
    }

    /// Two lists of Work's messages 3, 2 and 1 (3 and 2 unread) over one
    /// store, as two windows would hold them, with the sidebar agreeing.
    private func twoLists(
        imap: FakeImapClient,
        appState: AppState
    ) async throws -> (MessageListViewModel, MessageListViewModel) {
        let rows = [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: $0 == 1 ? [.seen] : []) }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        let second = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        for list in [first, second] {
            await fixture.track(list.client)
            list.window!.totalMessages = 3
            list.unseen = 2
        }
        store.counts.setFolderCounts(folderPath: work, unread: 2, total: 3)
        return (first, second)
    }

    // MARK: - Another window sees the write at once

    /// A swipe in one window leaves the other window's list at once; the
    /// other window's selection, on that message, lets go of it rather than
    /// moving on, since the user acted elsewhere.
    func testASwipeInOneWindowRemovesTheRowFromTheOtherAtOnce() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        second.selectedRefs = [ref(3)]
        let otherWindow = ListViewSelection(second, in: windowB)
        await imap.holdNext(.move)

        let dispose = Task { await first.dispose(first.envelopes[0]) }
        await imap.awaitHeld(.move)
        otherWindow.apply()

        XCTAssertEqual(second.rowRefs, [ref(2), ref(1)], "gone before the server answered")
        XCTAssertEqual(second.window!.totalMessages, 2)
        XCTAssertEqual(second.unseen, 1)
        XCTAssertEqual(second.selectedRefs, [], "the other window lets go of the row without advancing")
        XCTAssertNil(otherWindow.shown)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1, "one count change, not two")
        await imap.releaseHeld(.move)
        await dispose.value
        XCTAssertEqual(second.rowRefs, [ref(2), ref(1)])
        XCTAssertEqual(first.rowRefs, [ref(2), ref(1)])
    }

    /// The swipe's row stays in the record until its animation has played
    /// and it has left, even when the server answers first: until then a
    /// refresh mustn't pull it out under the animation, paging mustn't count
    /// it, and a second swipe mustn't reach it.
    func testASwipedRowStaysRecordedAsLeavingUntilItHasLeft() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, _) = try await twoLists(imap: imap, appState: appState)
        let shields = appState.mailStore.shields

        let dispose = Task { await first.dispose(first.envelopes[0]) }
        try await waitUntil { await !imap.moveCalls.isEmpty }
        var sawItLeaving = false
        while first.rowDisposalPhases[ref(3)] != nil {
            sawItLeaving = true
            XCTAssertTrue(shields.isRemoving(ref(3)), "recorded as leaving while it animates out")
            XCTAssertTrue(first.pendingRemovedRefs.contains(ref(3)))
            try await Task.sleep(for: .milliseconds(5))
        }
        await dispose.value

        XCTAssertTrue(sawItLeaving, "precondition: the server answered while the row was still animating")
        XCTAssertFalse(shields.isRemoving(ref(3)))
        XCTAssertEqual(first.rowRefs, [ref(2), ref(1)])
    }

    /// A failure that reached a list while it still had the row (it was
    /// built while the removal was out) doesn't swallow a later, real
    /// removal of the same message.
    func testAnOldFailureDoesNotSwallowALaterRemoval() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(Self.refused), .success(())])
        let appState = AppState()
        let rows = [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: [.seen]) }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        await imap.holdNext(.move)
        let refusedMove = Task { await first.moveTo(first.envelopes[0], destination: "Archive") }
        await imap.awaitHeld(.move)
        let late = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        await imap.releaseHeld(.move)
        await refusedMove.value
        XCTAssertEqual(late.rowRefs, [ref(3), ref(2), ref(1)], "precondition: the failure left the late list's row")

        await first.moveTo(try XCTUnwrap(first.envelope(for: ref(3))), destination: "Archive")

        XCTAssertEqual(late.rowRefs, [ref(2), ref(1)])
    }

    /// A refused move keeps the row recorded as leaving until the list has
    /// put it back itself: anything that runs between the server's answer
    /// and the list's own restore (a refresh merge, say) still finds the row
    /// shielded rather than absent and unrecorded.
    func testARefusedMoveStaysRecordedUntilTheListHasPutItBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(Self.refused)])
        let appState = AppState()
        let (first, _) = try await twoLists(imap: imap, appState: appState)
        let probe = RestoreProbe(store: appState.mailStore, list: first, ref: ref(3))

        await first.moveTo(first.envelopes[0], destination: "Archive")
        try await waitUntilOnMainActor { probe.checked }

        XCTAssertTrue(probe.coveredInBetween, "between the answer and the restore, the row was listed or recorded")
        XCTAssertEqual(first.rowRefs, [ref(3), ref(2), ref(1)])
        XCTAssertEqual(first.window!.totalMessages, 3)
    }

    /// A refused removal of several rows in one list puts them back in order
    /// in the other: each was pruned one by one, so the index each held is
    /// off by the rows pruned before it.
    func testARefusedBulkArchiveComesBackInOrderInTheOtherWindow() async throws {
        for (refused, partial) in [([5, 4, 3], false), ([5, 3], true)] as [([UInt32], Bool)] {
            let imap = FakeImapClient()
            let failure: Error = partial
                ? CabalmailError.bulkPartialFailure(succeeded: [5], failed: [3]) : Self.refused
            await imap.scriptMoveResults([.failure(failure)])
            let appState = AppState()
            let rows = [5, 4, 3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: [.seen]) }
            let store = appState.mailStore
            let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
            let second = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)

            await first.disposeMessages(refs: Set(refused.map { ref($0) }), action: .archive)

            let expected = partial ? [4, 3, 2, 1] : [5, 4, 3, 2, 1]
            XCTAssertEqual(second.rowRefs, expected.map { ref(UInt32($0)) }, "refused \(refused), partial \(partial)")
            XCTAssertEqual(first.rowRefs, expected.map { ref(UInt32($0)) }, "the acting list agrees")
        }
    }

    func testARefusedSwipeComesBackInTheOtherWindowToo() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(Self.refused)])
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        await imap.holdNext(.move)

        let dispose = Task { await first.dispose(first.envelopes[0]) }
        await imap.awaitHeld(.move)
        XCTAssertEqual(second.rowRefs, [ref(2), ref(1)], "precondition: it left the other window first")
        await imap.releaseHeld(.move)
        await dispose.value

        XCTAssertEqual(first.rowRefs, [ref(3), ref(2), ref(1)])
        XCTAssertEqual(second.rowRefs, [ref(3), ref(2), ref(1)])
        XCTAssertFalse(second.envelopes[0].flags.contains(.seen), "back unread, as it is on the server")
        XCTAssertEqual(second.unseen, 2)
        XCTAssertEqual(second.window!.totalMessages, 3)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 2)
        XCTAssertEqual(first.errorMessage, Self.refused.localizedDescription)
        XCTAssertNil(second.errorMessage, "the toast is the acting window's")
    }

    func testABulkArchiveInOneWindowRemovesTheRowsFromTheOther() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)

        await first.disposeMessages(refs: [ref(3), ref(1)], action: .archive)

        XCTAssertEqual(second.rowRefs, [ref(2)])
        XCTAssertEqual(second.window!.totalMessages, 1)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1)
    }

    func testAFlagInOneWindowShowsInTheOther() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)

        await first.setFlag(.flagged, add: true, envelope: first.envelopes[1])

        XCTAssertTrue(second.envelopes[1].flags.contains(.flagged))
    }

    // MARK: - Bulk mark-read moves the count at once (decision 8)

    func testABulkMarkReadMovesTheSidebarCountBeforeTheServerAnswers() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        // Five unread in the folder: the two loaded and three further down.
        appState.mailStore.counts.setFolderCounts(folderPath: work, unread: 5, total: 9)
        await imap.holdNext(.setFlags)

        let read = Task { await first.setSeen(true, refs: [ref(3), ref(2), ref(1)]) }
        await imap.awaitHeld(.setFlags)

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 3, "two flipped; 1 was read already")
        XCTAssertEqual(second.unseen, 3, "the other window's pill is the same number")
        await imap.releaseHeld(.setFlags)
        await read.value
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 3)
    }

    func testARefusedBulkMarkReadPutsTheCountAndTheRowsBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(Self.refused)])
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)

        await first.setSeen(true, refs: [ref(3), ref(2), ref(1)])

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 2)
        XCTAssertEqual(first.unseen, 2)
        XCTAssertEqual(second.unseen, 2)
        XCTAssertTrue(second.envelopes[2].flags.contains(.seen), "1 was read before, and still is")
        XCTAssertFalse(second.envelopes[0].flags.contains(.seen))
    }

    // MARK: - Global search clears the offline copy (#1869)

    func testArchivingFromGlobalSearchForgetsTheMessageInItsFoldersCaches() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let client = try await fixture.makeClient(imap: imap)
        let rows = [TestFixtures.makeEnvelope(uid: 5), TestFixtures.makeEnvelope(uid: 4, flags: [.seen])]
        try await fixture.seedSnapshot(client: client, folder: "INBOX", envelopes: rows)
        try await client.bodyCache.store(
            folder: "INBOX", uidValidity: fixture.uidValidity, uid: 5, bytes: Data("x".utf8)
        )
        await imap.scriptSearch(SearchResult(
            envelopes: [SearchedEnvelope(envelope: rows[0], folder: "INBOX")],
            totalEstimate: 1, nextCursor: nil, foldersSearched: ["INBOX"], truncated: false
        ))
        let search = MessageListViewModel(
            scope: .search, client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()), mailStore: appState.mailStore
        )
        search.searchQuery = "throwaway"
        await search.runSearch()
        XCTAssertEqual(search.rowRefs, [ref(5, in: "INBOX")], "precondition")

        await search.dispose(search.envelopes[0])

        let cached = await client.envelopeCache.snapshot(for: "INBOX")?.envelopes.keys.sorted()
        XCTAssertEqual(cached, [4], "the archived message left INBOX's offline list")
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: fixture.uidValidity, uid: 5)
        XCTAssertNil(body, "and its offline body, under INBOX's own UIDVALIDITY")
    }

    // MARK: - The reader

    /// The reader follows a flag a list changes on its message.
    func testTheReaderShowsAFlagAListChangesOnItsMessage() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, _) = try await twoLists(imap: imap, appState: appState)
        let reader = try await fixture.makeReader(imap: imap, envelope: first.envelopes[0], folderPath: work)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore, from: windowA)

        await first.setSeen(true, refs: [ref(3)])
        await first.setFlag(.flagged, add: true, envelope: first.envelopes[0])

        XCTAssertTrue(reader.isSeen)
        XCTAssertTrue(reader.isFlagged)
    }

    /// A reader's move of an unread message carries its count to the
    /// destination; it used to leave both counts until the next STATUS.
    func testAReadersMoveCarriesTheUnreadCount() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (first, _) = try await twoLists(imap: imap, appState: appState)
        appState.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 4, total: 10)
        let reader = try await fixture.makeReader(imap: imap, envelope: first.envelopes[0], folderPath: work)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore, from: windowA)

        await reader.move(to: "Projects")

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 5)
        XCTAssertEqual(first.rowRefs, [ref(2), ref(1)])
    }
}

/// Hears a list's refused removal of `ref` and, in the main-actor turn
/// queued right after it (before the list resumes from the write), checks
/// that the row is either listed or still recorded as leaving.
@MainActor
private final class RestoreProbe: MailEventSubscriber {
    let store: MailSessionStore
    let list: MessageListViewModel
    let ref: MessageRef
    private(set) var checked = false
    private(set) var coveredInBetween = false

    init(store: MailSessionStore, list: MessageListViewModel, ref: MessageRef) {
        self.store = store
        self.list = list
        self.ref = ref
        store.events.subscribe(self)
    }

    func receive(_ event: MailEvent) {
        guard case .restored(let restored, _) = event.change, restored == ref else { return }
        Task { @MainActor in
            coveredInBetween = store.shields.isRemoving(ref) || list.index(of: ref) != nil
            checked = true
        }
    }
}
