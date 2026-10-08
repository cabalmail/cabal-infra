import XCTest
import CabalmailKit
@testable import CabalmailUI

// Workstream 1.2 moved the mail state the folder list, message list, reader
// and composer share out of `AppState` into one `MailSessionStore`. Two
// properties carry the move. Sign-out resets the store in place, clearing
// exactly what `forgetAccountState` cleared on `AppState` and leaving the
// mail events alone: they keep reaching every subscriber. And every view
// model reads and writes the store it was built with: each test below builds
// over one `AppState`'s store and keeps a second, untouched `AppState` beside
// it as the negative control.
@MainActor
final class MailSessionStoreTests: XCTestCase {
    private var harness: SessionHarness!
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        harness = try SessionHarness()
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - Sign-out

    func testSignOutResetsTheStoreInPlaceAndLeavesTheEvents() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let store = state.mailStore
        let ref = MessageRef(folder: "Archive", uid: 9)
        let events = MailEventRecorder(store)
        store.counts.setFolderCounts(folderPath: "Archive", unread: 3, total: 40)
        store.counts.setFolderCounts(folderPath: "Projects", unread: 1, total: 8)
        store.counts.setSubscribedFolders(["INBOX", "Archive"])
        store.counts.savedFolderCounts.markSeeded("Lists")
        store.shields.recordConfirmedRemovals([MessageRef(folder: "Archive", uid: 5)])
        store.shields.setFlagWrite(MessageRef(folder: "Archive", uid: 6), inFlight: true)
        store.shields.setMoveInFlight(MessageRef(folder: "Projects", uid: 7), inFlight: true)
        store.events.post(.removed([ref]), from: nil)
        store.events.post(.restored(ref, markUnread: false), from: nil)
        store.events.post(.flagsChanged([ref], flag: .flagged, added: true), from: nil)
        store.events.post(.readAdvance(ref, advance: .nextUnread), from: nil)
        store.events.post(
            .draftReplaced(folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [3], survivingUID: 4)),
            from: nil
        )
        let posted = events.events
        XCTAssertNotNil(store.counts.savedFolderCounts.cache, "precondition: the session wired the saved counts")
        XCTAssertEqual(posted.count, 5, "precondition: every kind of event was posted and heard")

        await state.signOut()

        XCTAssertTrue(state.mailStore === store, "reset in place, never replaced")
        // What `forgetAccountState` cleared on `AppState` before the move...
        XCTAssertEqual(store.counts.folderUnreadCounts, [:])
        XCTAssertEqual(store.counts.folderTotalCounts, [:])
        XCTAssertNil(store.counts.subscribedFolderPaths)
        XCTAssertEqual(store.counts.savedFolderCounts.seededPaths, [])
        XCTAssertNil(store.counts.savedFolderCounts.cache)
        XCTAssertEqual(store.shields.confirmedRemovals, [:])
        XCTAssertEqual(store.shields.pendingFlagWriteRefs, [])
        XCTAssertEqual(store.shields.pendingMoveRefs, [])
        // ...and what it never touched: the events. Sign-out posts none, and
        // a subscriber from before it still hears the next one.
        XCTAssertEqual(events.events, posted, "sign-out posts no event")
        store.events.post(.removed([ref]), from: nil)
        XCTAssertEqual(events.events.count, 6, "the next event still reaches a subscriber from before sign-out")
        XCTAssertEqual(events.events.last?.change, .removed([ref]))
    }

    /// Sign-out zeroes the Inbox count by stopping the badge poller, which
    /// clears the system badge with it; the store's reset leaves it alone.
    func testTheResetLeavesTheInboxCountToTheBadgePoller() {
        let store = AppState().mailStore
        store.counts.setInboxUnread(5)
        defer { store.counts.setInboxUnread(0) }

        store.forgetAccount()

        XCTAssertEqual(store.counts.inboxUnreadCount, 5)
    }

    // MARK: - Each view model writes the store it was built with

    func testTheSidebarWritesTheStoreItWasBuiltWith() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(4)])
        await imap.scriptEmptyTrashResults([.success(())])
        let owner = AppState()
        let bystander = AppState()
        for state in [owner, bystander] {
            state.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 4, total: 20)
            state.mailStore.counts.setFolderCounts(folderPath: FolderTree.trashPath, unread: 3, total: 10)
        }
        let sidebar = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), mailStore: owner.mailStore)

        await sidebar.markAllRead(folderPath: "Projects")
        await sidebar.emptyTrash()

        XCTAssertNil(sidebar.errorMessage)
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Projects"], 0)
        XCTAssertEqual(owner.mailStore.counts.folderTotalCounts[FolderTree.trashPath], 0)
        XCTAssertEqual(owner.refreshRequestTick, 2, "both reach the owner's lists through the store's hook")
        XCTAssertEqual(bystander.mailStore.counts.folderUnreadCounts["Projects"], 4)
        XCTAssertEqual(bystander.mailStore.counts.folderTotalCounts[FolderTree.trashPath], 10)
        XCTAssertEqual(bystander.refreshRequestTick, 0)
    }

    func testAMessageListWritesTheStoreItWasBuiltWith() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(1)])
        let owner = AppState()
        let bystander = AppState()
        for state in [owner, bystander] {
            state.mailStore.counts.setFolderCounts(folderPath: "Work", unread: 2, total: 2)
        }
        let list = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2, flags: [.seen])],
            folderPath: "Work",
            mailStore: owner.mailStore
        )

        await list.setSeen(true, refs: [MessageRef(folder: "Work", uid: 1)])
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Work"], 1, "the read moved the owner's count")
        await list.moveTo(try XCTUnwrap(list.envelope(for: MessageRef(folder: "Work", uid: 2))), destination: "Archive")
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Work"], 1, "precondition: a read message moved")
        await list.markAllRead()

        XCTAssertNil(list.errorMessage)
        XCTAssertEqual(
            owner.mailStore.shields.confirmedRemovalRefs(folderPath: "Work"), [MessageRef(folder: "Work", uid: 2)]
        )
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Work"], 0)
        XCTAssertEqual(owner.refreshRequestTick, 1)
        XCTAssertEqual(bystander.mailStore.counts.folderUnreadCounts["Work"], 2)
        XCTAssertTrue(bystander.mailStore.shields.confirmedRemovalRefs(folderPath: "Work").isEmpty)
        XCTAssertEqual(bystander.refreshRequestTick, 0)
    }

    func testAReaderRelaysToTheStoreItWasWiredTo() async throws {
        let imap = FakeImapClient()
        let ref = MessageRef(folder: "Archive", uid: 7)
        let window = UUID()
        let owner = AppState()
        let bystander = AppState()
        let ownerEvents = MailEventRecorder(owner.mailStore)
        let bystanderEvents = MailEventRecorder(bystander.mailStore)
        let reader = try await fixture.makeReader(imap: imap, uid: 7, folderPath: "Archive")
        MessageDetailView.relayOutcomes(of: reader, to: owner.mailStore, from: window)

        owner.mailStore.counts.setFolderCounts(folderPath: "Archive", unread: 1, total: 5)
        await reader.toggleFlagged()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        await imap.holdNext(.move)
        let dispose = Task { await reader.dispose() }
        await imap.awaitHeld(.move)
        XCTAssertEqual(owner.mailStore.shields.pendingMoveRefs, [ref])
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Archive"], 0, "the dispose took its unread")
        await imap.releaseHeld(.move)
        await dispose.value

        let sender = ObjectIdentifier(reader)
        XCTAssertEqual(ownerEvents.events, [
            MailEvent(change: .flagsChanged([ref], flag: .flagged, added: true), origin: window, sender: sender),
            MailEvent(change: .removed([ref]), origin: window, sender: sender),
            MailEvent(change: .restored(ref, markUnread: true), origin: window, sender: sender),
        ], "each names the reader's window")
        XCTAssertEqual(
            owner.mailStore.counts.folderUnreadCounts["Archive"], 1, "the failed removal handed back its unread"
        )
        XCTAssertEqual(bystanderEvents.events, [])
        XCTAssertEqual(bystander.mailStore.shields.pendingMoveRefs, [])
        XCTAssertNil(bystander.mailStore.counts.folderUnreadCounts["Archive"])
    }
}
