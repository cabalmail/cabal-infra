import XCTest
import CabalmailKit
@testable import CabalmailUI

// The edges of the STATUS bounds (#1880; `StatusAcrossWriteTests` has the
// main cases): every path that applies a fetched STATUS passes when it was
// asked, a bound needs a counted base, the Check Inbox intent's ask window,
// the Flagged pill, and the record's other users.
@MainActor
final class StatusBoundEdgeTests: XCTestCase {
    private let work = "Work"
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

    /// Work's messages 3, 2 and 1, `unread` of them unread, counted by a
    /// STATUS this session; the folder's next STATUS reports the counts from
    /// before any write made now.
    private func countedWorkList(
        imap: FakeImapClient,
        appState: AppState,
        unread: Set<UInt32>
    ) async throws -> (MessageListViewModel, [Envelope]) {
        let rows = [3, 2, 1].map {
            TestFixtures.makeEnvelope(uid: UInt32($0), flags: unread.contains(UInt32($0)) ? [] : [.seen])
        }
        let list = try TestFixtures.makeModel(
            imap: imap, envelopes: rows, folderPath: work, mailStore: appState.mailStore
        )
        await fixture.track(list.client)
        let status = FolderStatus(messages: 3, unseen: unread.count, flagged: 0, uidValidity: 7, uidNext: 4)
        _ = list.window.applyStatusCounts(status)
        await imap.scriptInitialLoad(status: status, topEnvelopes: rows)
        return (list, list.envelopes)
    }

    // MARK: - Every path passes when its STATUS was asked

    /// A sort change asks STATUS before it drops the list and hands that
    /// reply to the refresh: it is bounded from when the probe asked.
    func testASortChangesProbeAskedBeforeAMarkReadCannotPutTheCountBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (list, rows) = try await countedWorkList(imap: imap, appState: appState, unread: [3, 2])
        await imap.holdNext(.status)

        let sort = Task { await list.window.setSort(SortCriterion(field: .subject, direction: .ascending)) }
        await imap.awaitHeld(.status)
        await list.setFlag(.seen, add: true, envelope: rows[0])
        await imap.releaseHeld(.status)
        await sort.value

        XCTAssertEqual(list.unseen, 1)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1)
    }

    /// A folder list showing a pill's search re-runs it on refresh, after a
    /// STATUS of the folder: that one is bounded from when it was asked too.
    func testAPillSearchsRefreshAskedBeforeAMarkReadCannotPutTheCountBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (list, rows) = try await countedWorkList(imap: imap, appState: appState, unread: [3, 2])
        await imap.scriptSearch(SearchResult(
            envelopes: [rows[0], rows[1]].map { SearchedEnvelope(envelope: $0, folder: work) },
            totalEstimate: 2, nextCursor: nil, foldersSearched: [work], truncated: false
        ))
        await list.applyFilter(.unread)
        XCTAssertTrue(list.isSearchActive, "precondition")
        await imap.holdNext(.status)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await list.setFlag(.seen, add: true, envelope: try XCTUnwrap(list.envelope(for: ref(3))))
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.unseen, 1)
    }

    func testARefreshAskedBeforeAFlagCannotPutTheFlaggedPillBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let (list, rows) = try await countedWorkList(imap: imap, appState: appState, unread: [])
        await imap.holdNext(.status)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await list.setFlag(.flagged, add: true, envelope: rows[0])
        XCTAssertEqual(list.flagged, 1, "precondition")
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.flagged, 1)
    }

    // MARK: - A bound needs a counted base

    /// A delta on a folder the sidebar has no count for guesses from 0. A
    /// STATUS bounded against that guess would show 0; it takes the reply.
    func testTheSidebarTakesAStatusWhenItsCountWasOnlyAGuess() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let store = appState.mailStore
        store.shields.beginFlagWrite([ref(3)], flag: .seen, added: true)
        store.counts.applyUnreadDelta(folderPath: work, delta: -1)
        await imap.scriptStatusResults([.success(FolderStatus(messages: 30, unseen: 12))])
        let sidebar = FolderListViewModel(client: try await fixture.makeClient(imap: imap), mailStore: store)

        await sidebar.refreshFolderCount(path: work)

        XCTAssertEqual(store.counts.folderUnreadCounts[work], 12)
        XCTAssertEqual(store.counts.folderTotalCounts[work], 30)
    }

    /// The first badge poll of a session has nothing to be bounded against.
    func testTheFirstBadgePollTakesItsAnswer() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let store = appState.mailStore
        defer { store.counts.setInboxUnread(0) }
        store.shields.beginFlagWrite([ref(3, in: "INBOX")], flag: .seen, added: true)
        store.counts.applyUnreadDelta(folderPath: "INBOX", delta: -1)

        XCTAssertEqual(store.polledInboxUnread(12, askedAt: .now), 12, "nothing counted the badge yet")
        store.counts.setInboxUnread(12)
        XCTAssertEqual(store.polledInboxUnread(13, askedAt: .now), 12, "now it is counted, and bounded")
    }

    /// Counts saved in an earlier launch are a guess at today's.
    func testAListSeededWithSavedCountsTakesItsFirstStatus() async throws {
        let appState = AppState()
        let list = try TestFixtures.makeModel(
            imap: FakeImapClient(), envelopes: [], folderPath: work, mailStore: appState.mailStore
        )
        list.unseen = 5
        appState.mailStore.shields.beginFlagWrite([ref(3)], flag: .seen, added: true)

        _ = list.window.applyStatusCounts(FolderStatus(messages: 30, unseen: 12, flagged: 0))
        XCTAssertEqual(list.unseen, 12)
        _ = list.window.applyStatusCounts(FolderStatus(messages: 30, unseen: 13, flagged: 0))
        XCTAssertEqual(list.unseen, 12, "the first STATUS counted it")
    }

    // MARK: - The Check Inbox intent

    /// The intent doesn't say when it asked: a mark-read that landed within
    /// the longest a request can be out bounds it, an older one doesn't.
    func testTheCheckInboxIntentIsBoundedByWritesWithinARequestsLength() async throws {
        for (endedAgo, expected) in [(Duration.seconds(10), 1), (.seconds(40), 2)] {
            let appState = AppState()
            let store = appState.mailStore
            defer { store.counts.setInboxUnread(0) }
            let client = try await fixture.makeClient(imap: FakeImapClient())
            store.counts.setFolderCounts(folderPath: "INBOX", unread: 2, total: 5)
            let read = ref(9, in: "INBOX")
            store.shields.beginFlagWrite([read], flag: .seen, added: true)
            store.counts.applyUnreadDelta(folderPath: "INBOX", delta: -1)
            store.shields.endFlagWrite([read], flag: .seen, added: true, at: .now - endedAgo)

            store.setInboxUnread(2, fetchedThrough: client)

            XCTAssertEqual(store.counts.inboxUnreadCount, expected, "write ended \(endedAgo) ago")
        }
    }

    // MARK: - The store's totals

    /// A STATUS asked before a removal the server has since confirmed can't
    /// put the sidebar's total back up.
    func testTheSidebarTotalStaysDownAfterAConfirmedRemoval() {
        let store = AppState().mailStore
        store.counts.setFolderCounts(folderPath: work, unread: 1, total: 2)
        let confirmedAt = ContinuousClock.now
        store.shields.recordConfirmedRemovals([ref(9)], at: confirmedAt)

        let stale = store.boundedFolderCounts(unread: 1, total: 3, folderPath: work, askedAt: confirmedAt - .seconds(1))
        let fresh = store.boundedFolderCounts(unread: 1, total: 3, folderPath: work, askedAt: confirmedAt + .seconds(1))

        XCTAssertEqual(stale.total, 2)
        XCTAssertEqual(fresh.total, 3)
    }

    // MARK: - The record's other users

    /// Two reader writes out at once: each holds its own place in the
    /// record until it answers, whichever answers first, so a STATUS asked
    /// before either is bounded both ways, and one asked once the second has
    /// answered only by the first, still out.
    func testOverlappingReaderWritesEachStayInTheRecordUntilTheyAnswer() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let shields = appState.mailStore.shields
        let reader = try await fixture.makeReader(imap: imap, uid: 3, folderPath: work)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)
        await imap.holdNext(.setFlags)
        let askedBefore = ContinuousClock.now

        let read = Task { await reader.setSeen(true) }
        await imap.awaitHeld(.setFlags)
        await reader.setSeen(false)
        let askedAfter = ContinuousClock.now

        XCTAssertTrue(shields.isWritingFlags(ref(3)), "the second write answered; the first is still out")
        XCTAssertEqual(shields.unreadBound(folderPath: work, askedAt: askedBefore), .held)
        XCTAssertEqual(
            shields.unreadBound(folderPath: work, askedAt: askedAfter), .lowerOnly,
            "a STATUS asked after the mark-unread answered counts it; only the mark-read may be missing"
        )
        await imap.releaseHeld(.setFlags)
        await read.value
        XCTAssertFalse(shields.isWritingFlags(ref(3)))
    }

    /// A swipe that reaches a row whose removal another list already has
    /// out lets go of the row it held open, and sends no second move. The
    /// first list's removal drops the row from every list that has it at
    /// once, so the second list here is built while it is out, from rows
    /// that still have it (as a list built from its saved rows would be).
    func testASwipeOnARowAnotherListIsRemovingLetsGoOfIt() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let rows = [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: [.seen]) }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        await imap.holdNext(.move)
        let dispose = Task { await first.dispose(first.envelopes[0]) }
        await imap.awaitHeld(.move)
        let second = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)

        await second.dispose(second.envelopes[0])

        XCTAssertEqual(second.rowGenerations[ref(3)], 1, "the held row was replaced")
        XCTAssertEqual(second.rowRefs.first, ref(3), "the row stays until its removal resolves")
        XCTAssertTrue(second.rowDisposalPhases.isEmpty)
        let moves = await imap.moveCalls.count
        XCTAssertEqual(moves, 1, "no second move")
        await imap.releaseHeld(.move)
        await dispose.value
    }
}
