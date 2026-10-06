import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: what rides beside the command ticks after its defect 11,
/// window-scoped menu commands (#1783), so workstream 3.1's focused-window
/// commands can match it one for one.
///
/// - The compose handoff on `AppState`: the parked seed and the forwarded
///   attachments are pop-once (`ComposeRequestRouter` and `ComposeView`
///   depend on it), and a mailto compose aimed at the main window last in
///   front reaches only it, or every window when none is recorded.
/// - The untargeted refresh senders: the sidebar's and the list's Mark All as
///   Read (cross-media plan decision 6, through `FolderMarkAllRead`) and
///   Empty Trash bump `refreshRequestTick` aimed at no window, so every
///   mounted list hard-reloads, even right after a command aimed at one.
///   Because the target is one shared slot, that same bump also re-aims an
///   earlier aimed tick SwiftUI has not delivered yet at every window; that
///   defect is pinned on its own in
///   `CommandTickCharacterizationTests.testAnUntargetedRefreshBeforeDeliveryReAimsAnEarlierAimedTickAtEveryWindow`.
///   `FolderMarkAllReadTests` covers the mark-read side effects; these
///   tests add the window reach.
@MainActor
final class CommandHandoffCharacterizationTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    // MARK: - T3: compose seed and attachment handoff

    func testThePendingComposeSeedPopsExactlyOnce() {
        let appState = AppState()
        let seed = Draft(to: ["someone@cabalmail.example"], subject: "mailto")
        appState.requestCompose(seed: seed, in: windowA)

        XCTAssertEqual(appState.consumePendingComposeSeed(), seed)
        XCTAssertNil(appState.pendingComposeSeed)
        XCTAssertNil(appState.consumePendingComposeSeed(), "a second router falls back to a new draft")
        XCTAssertEqual(appState.composeRequestTick, 1, "consuming the seed does not touch the tick")
    }

    /// Pins current behaviour, which looks like a defect: a second seeded
    /// request before the router pops the first (two mailto links in quick
    /// succession, or one arriving while an iPhone compose sheet is up)
    /// replaces the parked seed, so the first message is never composed.
    /// Tracked in #1824.
    func testASecondSeedBeforeThePopReplacesTheFirst() {
        let appState = AppState()
        let first = Draft(subject: "first")
        let second = Draft(subject: "second")
        appState.requestCompose(seed: first, in: windowA)
        appState.requestCompose(seed: second, in: windowA)

        XCTAssertEqual(appState.composeRequestTick, 2)
        XCTAssertEqual(appState.consumePendingComposeSeed(), second)
        XCTAssertNil(appState.consumePendingComposeSeed(), "the first seed is gone")
    }

    func testForwardedAttachmentsPopExactlyOncePerDraft() {
        let appState = AppState()
        let forwarded = UUID()
        let other = UUID()
        let report = Attachment(filename: "report.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let photo = Attachment(filename: "photo.jpg", mimeType: "image/jpeg", data: Data([4]))
        appState.stashComposeAttachments([report], for: forwarded)
        appState.stashComposeAttachments([photo], for: other)

        XCTAssertEqual(appState.consumeComposeAttachments(for: forwarded), [report])
        XCTAssertEqual(appState.consumeComposeAttachments(for: forwarded), [], "a restored scene composes without")
        XCTAssertEqual(appState.consumeComposeAttachments(for: other), [photo], "each draft keeps its own")
        XCTAssertEqual(appState.consumeComposeAttachments(for: UUID()), [], "an unknown draft gets nothing")
        XCTAssertEqual(appState.composeRequestTick, 0, "the stash is not a compose request")
    }

    func testRestashingADraftReplacesItsAttachments() {
        let appState = AppState()
        let draft = UUID()
        let old = Attachment(filename: "old.txt", mimeType: "text/plain", data: Data([1]))
        let new = Attachment(filename: "new.txt", mimeType: "text/plain", data: Data([2]))
        appState.stashComposeAttachments([old], for: draft)
        appState.stashComposeAttachments([new], for: draft)

        XCTAssertEqual(appState.consumeComposeAttachments(for: draft), [new])
    }

    /// The mailto handlers (`CabalmailApp`, `CabalmailMacApp`) pass
    /// `appState.lastActiveMainWindow` as the compose's window. Only
    /// `AppState`'s half is pinned here: the test restates that argument
    /// rather than running the handlers, which are view code, so a handler
    /// that changed its target would not fail it.
    func testAMailtoComposeReachesOnlyTheMainWindowLastInFront() {
        let appState = AppState()
        appState.noteActiveMainWindow(windowA)
        appState.requestCompose(seed: Draft(subject: "mailto"), in: appState.lastActiveMainWindow)

        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertFalse(appState.commandReaches(windowB))
    }

    /// Pins current behaviour, which looks like a defect: with no main window
    /// recorded (none has come to the front yet, or the last one closed) a
    /// mailto compose aims at no window, so every window's router answers.
    /// The first takes the seed and the others pop nil and open blank drafts
    /// (`ComposeRequestRouter`'s `consumePendingComposeSeed() ?? newDraft()`):
    /// today's latent multi-window double compose. As above, the handlers'
    /// argument is restated, not run.
    /// Tracked in #1824.
    func testAMailtoComposeWithNoWindowRecordedReachesEveryWindow() {
        let appState = AppState()
        appState.noteActiveMainWindow(windowA)
        appState.forgetMainWindow(windowA)
        XCTAssertNil(appState.lastActiveMainWindow)

        let seed = Draft(subject: "mailto")
        appState.requestCompose(seed: seed, in: appState.lastActiveMainWindow)

        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertTrue(appState.commandReaches(windowB))
        // What two routers answering the one tick each get.
        XCTAssertEqual(appState.consumePendingComposeSeed(), seed, "window A's router")
        XCTAssertNil(appState.consumePendingComposeSeed(), "window B's router opens a blank draft")
    }

    // MARK: - T4: untargeted refresh senders

    func testSidebarMarkAllReadSendsARefreshThatReachesEveryWindow() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(4)])
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 4, total: 20)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), appState: appState)
        appState.requestReply(in: windowA)
        let before = appState.refreshRequestTick

        await model.markAllRead(folderPath: "Projects")

        XCTAssertEqual(appState.refreshRequestTick, before + 1, "exactly one refresh")
        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertTrue(appState.commandReaches(windowB), "the refresh is aimed at no window, so B reloads too")
        XCTAssertEqual(appState.replyRequestTick, 1, "the earlier command's tick is untouched")
        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Projects"])
        XCTAssertNil(model.errorMessage)
    }

    /// Mailbox > Mark All as Read (Option-Command-T) is aimed at one window,
    /// but the confirmation's refresh is not: every window's list reloads.
    func testAnAimedMarkFolderReadEndsInARefreshThatReachesEveryWindow() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(2)])
        let appState = AppState()
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [], folderPath: "Sent", appState: appState)
        appState.requestMarkFolderRead(in: windowA)
        XCTAssertFalse(appState.commandReaches(windowB))

        await model.markAllRead()

        XCTAssertEqual(appState.markFolderReadRequestTick, 1)
        XCTAssertEqual(appState.refreshRequestTick, 1)
        XCTAssertTrue(appState.commandReaches(windowB))
        XCTAssertNil(model.errorMessage)
    }

    func testEmptyTrashZeroesTrashAndSendsARefreshThatReachesEveryWindow() async throws {
        let imap = FakeImapClient()
        await imap.scriptEmptyTrashResults([.success(())])
        let client = try TestFixtures.makeClient(imap: imap)
        try await client.envelopeCache.store(trashSnapshot(), for: FolderTree.trashPath)
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Trash", unread: 3, total: 10)
        let model = FolderListViewModel(client: client, appState: appState)
        appState.requestReply(in: windowA)
        let before = appState.refreshRequestTick

        await model.emptyTrash()

        let calls = await imap.emptyTrashCalls
        XCTAssertEqual(calls, ["Trash"])
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Trash"], 0)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["Trash"], 0)
        let snapshot = await client.envelopeCache.snapshot(for: "Trash")
        XCTAssertNil(snapshot, "the cached Trash rows are dropped")
        XCTAssertEqual(appState.refreshRequestTick, before + 1, "exactly one refresh")
        XCTAssertTrue(appState.commandReaches(windowB), "the refresh is aimed at no window")
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedEmptyTrashLeavesTrashTheTickAndTheTargetAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptEmptyTrashResults([.failure(CabalmailError.network("offline"))])
        let client = try TestFixtures.makeClient(imap: imap)
        try await client.envelopeCache.store(trashSnapshot(), for: FolderTree.trashPath)
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Trash", unread: 3, total: 10)
        let model = FolderListViewModel(client: client, appState: appState)
        appState.requestReply(in: windowA)

        await model.emptyTrash()

        let calls = await imap.emptyTrashCalls
        XCTAssertEqual(calls, ["Trash"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Trash"], 3)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["Trash"], 10)
        let snapshot = await client.envelopeCache.snapshot(for: "Trash")
        XCTAssertEqual(snapshot?.envelopes.count, 2)
        XCTAssertEqual(appState.refreshRequestTick, 0)
        XCTAssertFalse(appState.commandReaches(windowB), "the reply's target still stands")
    }

    private func trashSnapshot() -> EnvelopeCache.Snapshot {
        EnvelopeCache.Snapshot(
            uidValidity: 1,
            uidNext: 3,
            envelopes: [1: TestFixtures.makeEnvelope(uid: 1), 2: TestFixtures.makeEnvelope(uid: 2)]
        )
    }
}
