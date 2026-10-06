import XCTest
import CabalmailKit
@testable import CabalmailUI

// Workstream 1.2 moved the mail state the folder list, message list, reader
// and composer share out of `AppState` into one `MailSessionStore`. Two
// properties carry the move. Sign-out resets the store in place, clearing
// exactly what `forgetAccountState` cleared on `AppState` and leaving the
// signals and their ticks. And every view model reads and writes the store
// it was built with: each test below builds over one `AppState`'s store and
// keeps a second, untouched `AppState` beside it as the negative control.
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

    /// Every signal the store carries, with the one tick tests can read.
    private struct SignalSnapshot: Equatable {
        let disposed: DisposedEnvelope?
        let failed: FailedRemoval?
        let failedTick: Int
        let flagChange: EnvelopeFlagChange?
        let readAdvance: ReadAdvanceRequest?
        let draftReplaced: DraftReplacedSignal?

        @MainActor init(_ signals: MessageSignals) {
            disposed = signals.lastDisposedEnvelope
            failed = signals.lastFailedRemoval
            failedTick = signals.failedRemovalTick
            flagChange = signals.lastEnvelopeFlagChange
            readAdvance = signals.lastReadAdvanceRequest
            draftReplaced = signals.lastDraftReplaced
        }
    }

    func testSignOutResetsTheStoreInPlaceAndLeavesTheSignals() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let store = state.mailStore
        let ref = MessageRef(folder: "Archive", uid: 9)
        store.counts.setFolderCounts(folderPath: "Archive", unread: 3, total: 40)
        store.counts.setFolderCounts(folderPath: "Projects", unread: 1, total: 8)
        store.counts.setSubscribedFolders(["INBOX", "Archive"])
        store.counts.savedFolderCounts.markSeeded("Lists")
        store.shields.recordConfirmedRemovals([MessageRef(folder: "Archive", uid: 5)])
        store.shields.setFlagWrite(MessageRef(folder: "Archive", uid: 6), inFlight: true)
        store.shields.setMoveInFlight(MessageRef(folder: "Projects", uid: 7), inFlight: true)
        store.signals.signalDisposed(ref)
        store.signalRemovalFailed(ref)
        store.signalFlagChange(ref, flag: .flagged, added: true)
        store.signals.signalReadAdvance(ref, advance: .nextUnread)
        store.signals.signalDraftReplaced(
            folderPath: "Drafts", replacement: DraftReplacement(retiredUIDs: [3], survivingUID: 4)
        )
        let signals = SignalSnapshot(store.signals)
        XCTAssertNotNil(store.counts.savedFolderCounts.cache, "precondition: the session wired the saved counts")
        XCTAssertNotNil(signals.draftReplaced, "precondition: every signal was sent")

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
        // ...and what it never touched: every signal and its tick.
        XCTAssertEqual(SignalSnapshot(store.signals), signals, "every signal survives sign-out")
        store.signals.signalDisposed(ref)
        XCTAssertEqual(
            store.signals.lastDisposedEnvelope?.tick, 2, "the tick runs on, so the next signal still fires .onChange"
        )
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
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)],
            folderPath: "Work",
            mailStore: owner.mailStore
        )

        await list.setSeen(true, refs: [MessageRef(folder: "Work", uid: 1)])
        XCTAssertEqual(owner.mailStore.counts.folderUnreadCounts["Work"], 1, "the read moved the owner's count")
        await list.confirmRemoval(from: "Work", uids: [2])
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
        let owner = AppState()
        let bystander = AppState()
        let reader = try await fixture.makeReader(imap: imap, uid: 7, folderPath: "Archive")
        MessageDetailView.relayOutcomes(of: reader, to: owner.mailStore)

        await reader.toggleFlagged()
        reader.onMoveInFlight?(true)
        reader.onMoveFailed?(true)

        XCTAssertEqual(owner.mailStore.signals.lastEnvelopeFlagChange?.ref, ref)
        XCTAssertEqual(owner.mailStore.shields.pendingMoveRefs, [ref])
        XCTAssertEqual(owner.mailStore.signals.lastFailedRemoval?.ref, ref)
        XCTAssertEqual(
            owner.mailStore.counts.folderUnreadCounts["Archive"], 1, "the failed removal handed back its unread"
        )
        XCTAssertNil(bystander.mailStore.signals.lastEnvelopeFlagChange)
        XCTAssertEqual(bystander.mailStore.shields.pendingMoveRefs, [])
        XCTAssertNil(bystander.mailStore.signals.lastFailedRemoval)
        XCTAssertNil(bystander.mailStore.counts.folderUnreadCounts["Archive"])
    }
}
