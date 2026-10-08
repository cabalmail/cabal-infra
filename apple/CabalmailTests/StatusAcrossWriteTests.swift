import XCTest
import CabalmailKit
@testable import CabalmailUI

// The unread count gap the tester found under #1880: a STATUS asked before a
// mark-read landed still counts the message unread, and when it answered it
// put the count back up -- in the list's Unread pill, in the sidebar, and on
// the Inbox badge. Every write is now bracketed in the store's one record
// (`MessageShields`), and every writer of a fetched STATUS bounds its counts
// by the writes the reply may predate. Each test holds a STATUS at the
// server, makes the write while it is out, then lets it answer with the
// count from before the write.
@MainActor
final class StatusAcrossWriteTests: XCTestCase {
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

    /// A list of Work's three messages, `unread` of them unread, its pills
    /// and the sidebar agreeing, over `appState`'s store; the next STATUS of
    /// the folder reports `statusUnread` and parks until released.
    private func heldWorkList(
        imap: FakeImapClient,
        appState: AppState,
        unread: Set<UInt32>,
        statusUnread: Int
    ) async throws -> MessageListViewModel {
        let rows = [3, 2, 1].map {
            TestFixtures.makeEnvelope(uid: UInt32($0), flags: unread.contains(UInt32($0)) ? [] : [.seen])
        }
        let list = try TestFixtures.makeModel(
            imap: imap, envelopes: rows, folderPath: work, mailStore: appState.mailStore
        )
        await fixture.track(list.client)
        // A STATUS this session has counted the folder: the base the next
        // one is bounded against.
        _ = list.window.applyStatusCounts(FolderStatus(messages: 3, unseen: unread.count, flagged: 0))
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], unread.count, "precondition")
        await imap.scriptInitialLoad(
            status: FolderStatus(messages: 3, unseen: statusUnread, flagged: 0, uidValidity: 7, uidNext: 4),
            topEnvelopes: rows
        )
        await imap.holdNext(.status)
        return list
    }

    // MARK: - The list's pill and the sidebar, through the list's refresh

    /// The issue's case: the reader marks the message read on open while a
    /// refresh's STATUS is out.
    func testARefreshAskedBeforeTheReadersMarkReadCannotPutTheCountBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await heldWorkList(imap: imap, appState: appState, unread: [3, 2], statusUnread: 2)
        let reader = try await fixture.makeReader(
            imap: imap, envelope: try XCTUnwrap(list.envelope(for: ref(3))), folderPath: work
        )
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await reader.setSeen(true)
        XCTAssertEqual(list.unseen, 1, "precondition: the read moved the pill")
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1, "precondition: and the sidebar")
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.unseen, 1, "the Unread pill stays down")
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1, "the sidebar stays down")
    }

    func testARefreshAskedBeforeAListMarkReadCannotPutTheCountBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await heldWorkList(imap: imap, appState: appState, unread: [3, 2], statusUnread: 2)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await list.setFlag(.seen, add: true, envelope: try XCTUnwrap(list.envelope(for: ref(3))))
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.unseen, 1)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1)
    }

    /// The mirror image: a mark-unread can't be taken back by a STATUS
    /// asked before it landed.
    func testARefreshAskedBeforeAMarkUnreadCannotLowerTheCount() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await heldWorkList(imap: imap, appState: appState, unread: [2], statusUnread: 1)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await list.setSeen(false, refs: [ref(3)])
        XCTAssertEqual(list.unseen, 2, "precondition")
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.unseen, 2)
    }

    /// Negative control: with no write while it was out, the same STATUS
    /// moves the counts as it always did.
    func testARefreshWithNoWriteOutMovesTheCountsAsBefore() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await heldWorkList(imap: imap, appState: appState, unread: [3], statusUnread: 2)

        let refresh = Task { await list.refresh() }
        await imap.awaitHeld(.status)
        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(list.unseen, 2)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 2)
    }

    // MARK: - The sidebar's own refresh

    func testTheSidebarsStatusAskedBeforeAMarkReadCannotPutTheBadgeBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await heldWorkList(imap: imap, appState: appState, unread: [3, 2], statusUnread: 2)
        let sidebar = FolderListViewModel(client: list.client, mailStore: appState.mailStore)

        let count = Task { await sidebar.refreshFolderCount(path: work) }
        await imap.awaitHeld(.status)
        await list.setFlag(.seen, add: true, envelope: try XCTUnwrap(list.envelope(for: ref(3))))
        await imap.releaseHeld(.status)
        await count.value

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts[work], 1)
    }

    // MARK: - The Inbox badge poller

    func testTheBadgePollAskedBeforeAMarkReadCannotPutTheBadgeBack() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let store = appState.mailStore
        defer { store.counts.setInboxUnread(0) }
        let client = try await fixture.makeClient(imap: imap)
        let rows = [TestFixtures.makeEnvelope(uid: 3), TestFixtures.makeEnvelope(uid: 2)]
        let list = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: "INBOX", mailStore: store)
        store.counts.setFolderCounts(folderPath: "INBOX", unread: 2, total: 2)
        await imap.scriptStatusResults([.success(FolderStatus(messages: 2, unseen: 2))])
        await imap.holdNext(.status)
        // The poller as `AppState` wires it: its bound is the store's.
        let pollers = appState.sessionManager.pollers
        let writes = BadgeWrites()
        pollers.client = { client }
        pollers.inboxUnreadChanged = {
            writes.values.append($0)
            store.counts.setInboxUnread($0)
        }

        pollers.startInboxBadgePolling(requestAuthorization: {})
        let loop = try XCTUnwrap(pollers.inboxBadgeTask)
        await imap.awaitHeld(.status)
        await list.setFlag(.seen, add: true, envelope: rows[0].inFolder("INBOX"))
        XCTAssertEqual(store.counts.inboxUnreadCount, 1, "precondition: the read moved the badge")
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !writes.values.isEmpty }
        loop.cancel()

        XCTAssertEqual(writes.values, [1], "the poll answered with 2, and the badge stays at 1")
        XCTAssertEqual(store.counts.inboxUnreadCount, 1)
    }

    // MARK: - One record for every list

    /// A write pending in one list shields another list's merge: the record
    /// is the store's, not each list's own.
    func testAWritePendingInOneListShieldsAnotherListsMerge() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let rows = [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: [.seen]) }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        let second = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        await fixture.track(first.client)
        await fixture.track(second.client)
        // The second list shows 3 flagged, as it will once it hears the
        // first list's change; the server's page doesn't have it yet.
        second.applyFlagChange(ref(3), flag: .flagged, added: true)
        await imap.holdNext(.setFlags)
        await imap.holdNext(.move)

        let flag = Task { await first.setFlag(.flagged, add: true, envelope: rows[0].inFolder(self.work)) }
        await imap.awaitHeld(.setFlags)
        let dispose = Task { await first.dispose(rows[1].inFolder(self.work)) }
        await imap.awaitHeld(.move)
        let merged = second.window.shieldFetched(rows)

        XCTAssertEqual(merged.map { second.rowRef(for: $0) }, [ref(3), ref(1)], "2 is being removed by the first list")
        XCTAssertTrue(
            try XCTUnwrap(merged.first).flags.contains(.flagged),
            "3's flag write keeps the second list's flags over the stale page"
        )

        await imap.releaseHeld(.setFlags)
        await imap.releaseHeld(.move)
        await flag.value
        await dispose.value
    }

    /// The reader's bracket names its write, so the record knows which way
    /// a STATUS asked meanwhile may move the count.
    func testTheReadersMarkReadIsInTheRecordWithItsDirection() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let reader = try await fixture.makeReader(imap: imap, uid: 3, folderPath: work)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)
        await imap.holdNext(.setFlags)
        let shields = appState.mailStore.shields
        let askedAt = ContinuousClock.now

        let read = Task { await reader.setSeen(true) }
        await imap.awaitHeld(.setFlags)
        XCTAssertTrue(shields.isWritingFlags(ref(3)))
        XCTAssertEqual(shields.unreadBound(folderPath: work, askedAt: askedAt), .lowerOnly)
        await imap.releaseHeld(.setFlags)
        await read.value

        XCTAssertFalse(shields.isWritingFlags(ref(3)))
        XCTAssertEqual(
            shields.unreadBound(folderPath: work, askedAt: askedAt), .lowerOnly,
            "a STATUS asked before it landed is still bounded"
        )
    }
}

/// What the badge poller wrote, in order.
@MainActor
private final class BadgeWrites {
    var values: [Int] = []
}
