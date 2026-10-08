import XCTest
import CabalmailKit
@testable import CabalmailUI

// The message list's Unread and Flagged pills are the mail store's counts
// for its folder, the numbers the sidebar shows (2.1 D). Before, the list
// kept its own: its own archive left its Unread pill where it was while the
// sidebar dropped, a reload or leaving a search zeroed the pills until a
// STATUS answered, Mark All as Read left them until the reload, and a folder
// opened offline showed a pill count with no sidebar badge.
@MainActor
final class PillsMatchSidebarTests: XCTestCase {
    private let work = "Work"
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

    /// `folder`'s messages 3, 2 and 1 (3 and 2 unread, 2 flagged), counted
    /// by a STATUS this session.
    private func countedList(
        imap: FakeImapClient,
        appState: AppState,
        folder: String? = nil
    ) async throws -> MessageListViewModel {
        let path = folder ?? work
        let rows = [
            TestFixtures.makeEnvelope(uid: 3),
            TestFixtures.makeEnvelope(uid: 2, flags: [.flagged]),
            TestFixtures.makeEnvelope(uid: 1, flags: [.seen]),
        ]
        let list = try TestFixtures.makeModel(
            imap: imap, envelopes: rows, folderPath: path, mailStore: appState.mailStore
        )
        await fixture.track(list.client)
        _ = list.applyStatusCounts(FolderStatus(messages: 3, unseen: 2, flagged: 1, uidValidity: 7, uidNext: 4))
        return list
    }

    private func sidebar(_ appState: AppState, _ folder: String? = nil) -> (unread: Int?, flagged: Int?) {
        let path = folder ?? work
        return (appState.mailStore.counts.folderUnreadCounts[path], appState.mailStore.counts.folderFlaggedCounts[path])
    }

    // MARK: - A list's own writes

    /// A list's own move and bulk archive take the moved messages out of its
    /// pills at once, with the sidebar, and a refusal puts both back. Before,
    /// the list sent the change and so never heard it: its pills waited for
    /// the next STATUS.
    func testAListsOwnRemovalsMoveItsPillsWithTheSidebar() async throws {
        for bulk in [false, true] {
            let imap = FakeImapClient()
            await imap.scriptMoveResults([.failure(Self.refused)])
            let appState = AppState()
            let list = try await countedList(imap: imap, appState: appState)
            await imap.holdNext(.move)

            let move = Task {
                if bulk {
                    await list.disposeMessages(refs: [self.ref(3), self.ref(2)], action: .archive)
                } else {
                    await list.moveTo(list.envelopes[1], destination: "Projects")
                }
            }
            await imap.awaitHeld(.move)
            let expectedUnread = bulk ? 0 : 1
            XCTAssertEqual(list.unseen, expectedUnread, "bulk \(bulk)")
            XCTAssertEqual(list.flagged, 0, "bulk \(bulk)")
            XCTAssertEqual(sidebar(appState).unread, expectedUnread, "bulk \(bulk): the same number")
            await imap.releaseHeld(.move)
            await move.value

            XCTAssertEqual(list.unseen, 2, "bulk \(bulk): back on refusal")
            XCTAssertEqual(list.flagged, 1, "bulk \(bulk)")
            XCTAssertEqual(sidebar(appState).unread, 2, "bulk \(bulk)")
        }
    }

    func testAPurgeOfAFlaggedUnreadMessageLowersBothPills() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState, folder: FolderTree.trashPath)

        await list.purgeMessages(refs: [ref(2, in: FolderTree.trashPath)])

        XCTAssertEqual(list.unseen, 1)
        XCTAssertEqual(list.flagged, 0)
        XCTAssertEqual(sidebar(appState, FolderTree.trashPath).unread, 1)
    }

    /// A list's flag toggle moves its Flagged pill with the store's count, and
    /// a folder the store has no flagged count for gets none.
    func testAListsFlagToggleMovesItsFlaggedPill() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState)

        await list.setFlag(.flagged, add: true, envelope: list.envelopes[0])
        XCTAssertEqual(list.flagged, 2)
        await imap.scriptFlagResults([.failure(Self.refused)])
        await list.setFlag(.flagged, add: false, envelope: list.envelopes[0])
        XCTAssertEqual(list.flagged, 2, "the refused unflag took nothing")
    }

    // MARK: - The reader

    func testTheReaderArchivingAFlaggedMessageLowersTheFlaggedPill() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState)
        let reader = try await fixture.makeReader(imap: imap, envelope: list.envelopes[1], folderPath: work)
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)

        await reader.dispose()

        XCTAssertEqual(list.flagged, 0)
        XCTAssertEqual(list.unseen, 1)
        XCTAssertEqual(list.rowRefs, [ref(3), ref(1)])
    }

    // MARK: - Reloads and searches

    /// Leaving a search used to zero the pills until the folder's STATUS
    /// answered; now they keep the folder's counts.
    func testLeavingASearchKeepsThePillsWhileTheStatusIsOut() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState)
        await imap.scriptSearch(SearchResult(
            envelopes: [SearchedEnvelope(envelope: list.envelopes[0], folder: work)],
            totalEstimate: 1, nextCursor: nil, foldersSearched: [work], truncated: false
        ))
        await list.applyFilter(.unread)
        XCTAssertTrue(list.isSearchActive, "precondition")
        await imap.scriptInitialLoad(
            status: FolderStatus(messages: 3, unseen: 2, flagged: 1, uidValidity: 7, uidNext: 4),
            topEnvelopes: [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0)) }
        )
        await imap.holdNext(.status)

        let clear = Task { await list.clearSearch() }
        await imap.awaitHeld(.status)

        XCTAssertEqual(list.unseen, 2)
        XCTAssertEqual(list.flagged, 1)
        await imap.releaseHeld(.status)
        await clear.value
    }

    /// Mark All as Read zeroes the pill at once, with the sidebar, rather
    /// than when the reload it asks for answers (which, offline, it never
    /// did).
    func testMarkAllAsReadZeroesThePillAtOnce() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(2)])
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState)

        await list.markAllRead()

        XCTAssertEqual(list.unseen, 0)
        XCTAssertEqual(sidebar(appState).unread, 0)
    }

    func testEmptyTrashZeroesTheFlaggedPill() async throws {
        let imap = FakeImapClient()
        await imap.scriptEmptyTrashResults([.success(())])
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState, folder: FolderTree.trashPath)
        let folders = FolderListViewModel(client: list.client, mailStore: appState.mailStore)

        await folders.emptyTrash()

        XCTAssertEqual(list.flagged, 0)
        XCTAssertEqual(list.unseen, 0)
    }

    // MARK: - Saved counts

    /// A folder opened offline that the sidebar doesn't seed (an unsubscribed
    /// one) shows the same count on its badge as on its pill.
    func testAFolderOpenedOfflineShowsOneCountOnItsBadgeAndPill() async throws {
        let offline = OfflineFolderFixture()
        let client = try offline.makeClient(folderState: await offline.savedState())
        let appState = AppState()
        let list = MessageListViewModel(
            folder: Folder(path: "Archive"), client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()), mailStore: appState.mailStore
        )

        await list.loadInitial()

        XCTAssertEqual(list.unseen, 3)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Archive"], 3, "the sidebar badge")
        XCTAssertEqual(list.allCount, 11)
    }

    func testAListsSeedNeverReplacesACountTheSessionHas() async throws {
        let offline = OfflineFolderFixture()
        let client = try offline.makeClient(folderState: await offline.savedState())
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 7, total: 30)
        let list = offline.makeListModel(client: client, mailStore: appState.mailStore)

        await list.seedSavedCounts()

        XCTAssertEqual(list.unseen, 7)
        XCTAssertEqual(list.flagged, 1, "the flagged count the session had none of is seeded")
    }

    func testASeedAfterSignOutWritesNothing() async throws {
        let offline = OfflineFolderFixture()
        let client = try offline.makeClient(folderState: await offline.savedState())
        let appState = AppState()
        let list = offline.makeListModel(client: client, mailStore: appState.mailStore)
        appState.sessionManager.teardownGate.markEnded(client)

        await list.seedSavedCounts()

        XCTAssertNil(appState.mailStore.counts.folderUnreadCounts["INBOX"])
        XCTAssertNil(appState.mailStore.counts.folderFlaggedCounts["INBOX"])
    }

    /// The sidebar drops the badges it seeded from a saved copy once a live
    /// folder list arrives; the folder a list has open keeps its counts, as
    /// its pills show them.
    func testALiveFolderListDoesNotBlankTheOpenFoldersCounts() async throws {
        let offline = OfflineFolderFixture()
        let cache = await offline.savedState()
        let client = try offline.makeClient(folderState: cache)
        let appState = AppState()
        let counts = appState.mailStore.counts
        for path in ["INBOX", "Projects"] {
            let lastKnown = await cache.lastKnownStatus(for: path)
            let saved = try XCTUnwrap(lastKnown)
            XCTAssertTrue(counts.seed(folderPath: path, from: saved), "precondition")
            counts.savedFolderCounts.markSeeded(path)
        }
        let list = offline.makeListModel(client: client, mailStore: appState.mailStore)
        await list.seedSavedCounts()

        counts.clearSeeded()

        XCTAssertEqual(list.unseen, 2, "the open folder keeps its counts")
        XCTAssertNil(counts.folderUnreadCounts["Projects"], "another seeded badge is dropped, as before")
    }

    /// A reply that may predate a removal saves what is shown; with nothing
    /// shown for the folder it saves nothing, rather than a 0 over the real
    /// saved count.
    func testAReplyPredatingARemovalWithNoCountShownSavesNothing() async throws {
        let offline = OfflineFolderFixture()
        let cache = await offline.savedState()
        let appState = AppState()
        appState.mailStore.counts.savedFolderCounts.cache = cache
        let list = offline.makeListModel(
            client: try offline.makeClient(folderState: cache), mailStore: appState.mailStore
        )

        _ = list.applyStatusCounts(FolderStatus(messages: 30, unseen: 7, flagged: 3), mayPredateRemoval: true)
        // A later change that is saved, as a marker the first write would
        // have landed before.
        appState.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 9, total: 40)
        try await eventually { await cache.lastKnownStatus(for: "Projects")?.unseen == 9 }

        let inbox = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(inbox?.unseen, 2)
        XCTAssertEqual(inbox?.messages, 22)
        XCTAssertNil(appState.mailStore.counts.folderUnreadCounts["INBOX"])
    }

    /// Once the list that adopted a seeded folder has gone, a live folder
    /// list drops that seeded badge as any other.
    func testASeededFolderIsDroppedOnceTheListShowingItHasGone() async throws {
        let offline = OfflineFolderFixture()
        let cache = await offline.savedState()
        let client = try offline.makeClient(folderState: cache)
        let appState = AppState()
        let counts = appState.mailStore.counts
        var list: MessageListViewModel? = offline.makeListModel(client: client, mailStore: appState.mailStore)
        await list?.seedSavedCounts()
        XCTAssertEqual(counts.folderUnreadCounts["INBOX"], 2, "precondition: the list seeded it")
        counts.clearSeeded()
        XCTAssertEqual(counts.folderUnreadCounts["INBOX"], 2, "precondition: kept while the list is open")

        list = nil
        counts.clearSeeded()

        XCTAssertNil(counts.folderUnreadCounts["INBOX"])
    }

    // MARK: - Which counts bound a STATUS

    /// A count a STATUS set long ago may have changed elsewhere since, so it
    /// bounds nothing: a reopened folder's first STATUS is taken as it comes
    /// even with a write out. A fresh one still bounds it (#1880).
    func testOnlyAFreshCountBoundsAStatus() async throws {
        let imap = FakeImapClient()
        let appState = AppState()
        let list = try await countedList(imap: imap, appState: appState)
        appState.mailStore.shields.beginFlagWrite([ref(3)], flag: .seen, added: true)
        appState.mailStore.counts.applyUnreadDelta(folderPath: work, delta: -1)
        let reply = FolderStatus(messages: 9, unseen: 6, flagged: 4)

        _ = list.applyStatusCounts(reply)
        XCTAssertEqual(list.unseen, 1, "fresh: held at what is shown")
        XCTAssertEqual(list.flagged, 4, "no flag write out: taken")

        _ = list.applyStatusCounts(reply, askedAt: .now + MailCounts.countFreshness + .seconds(1))
        XCTAssertEqual(list.unseen, 6, "stale: taken as it comes")
    }

    /// A reply that may predate a removal makes what it shows a base for the
    /// next reply, which a write still out then bounds.
    func testAReplyPredatingARemovalCountsWhatItShows() async throws {
        let offline = OfflineFolderFixture()
        let client = try offline.makeClient(folderState: await offline.savedState())
        let appState = AppState()
        let list = offline.makeListModel(client: client, mailStore: appState.mailStore)
        await list.seedSavedCounts()
        XCTAssertEqual(list.unseen, 2, "precondition: seeded, not counted")

        _ = list.applyStatusCounts(FolderStatus(messages: 22, unseen: 2, flagged: 1), mayPredateRemoval: true)
        appState.mailStore.shields.beginFlagWrite([MessageRef(folder: "INBOX", uid: 21)], flag: .seen, added: true)
        appState.mailStore.counts.applyUnreadDelta(folderPath: "INBOX", delta: -1)
        _ = list.applyStatusCounts(FolderStatus(messages: 22, unseen: 2, flagged: 1))

        XCTAssertEqual(list.unseen, 1, "the mark-read still out holds the count down")
    }
}
