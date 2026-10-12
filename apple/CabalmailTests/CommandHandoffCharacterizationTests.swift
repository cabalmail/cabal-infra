import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: what rides beside the window commands after its defect 11,
/// window-scoped menu commands (#1783). Ported by workstream 3.3 from the
/// compose tick and its one parked seed to `ComposeCoordinator`: every row
/// is the check it was, except the two #1824 defects it pinned, which are
/// fixed and pinned as fixed.
///
/// - The compose handoff (`AppState.compose`): a waiting seed and a
///   forward's attachments are taken once (`ComposeRequestRouter` and
///   `ComposeView` depend on it), a second seed waits behind the first, and
///   a mailto compose reaches only the main window last in front, or one
///   window when none is recorded.
/// - The data-change reloads: the sidebar's and the list's Mark All as
///   Read (cross-media plan decision 6, through `FolderMarkAllRead`) and
///   Empty Trash bump the mail store's `listRefreshTick` once, so every
///   mounted list hard-reloads, and touch no compose request, so one
///   waiting for a window just before still waits for that window (#1824;
///   pinned on its own in
///   `CommandTickCharacterizationTests.testADataChangeReloadLeavesAWaitingComposeWithItsWindow`).
///   `FolderMarkAllReadTests` covers the mark-read side effects; these
///   tests add the window reach.
@MainActor
final class CommandHandoffCharacterizationTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    // MARK: - T3: compose seed and attachment handoff

    func testAWaitingComposeSeedIsShownExactlyOnce() {
        let appState = AppState()
        let seed = Draft(to: ["someone@cabalmail.example"], subject: "mailto")
        appState.compose.open(seed: seed, from: windowA)
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [seed], "no surface yet: it waits")

        let first = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let second = RecordingComposeSurface(window: windowA).register(with: appState.compose)

        XCTAssertEqual(first.shown, [seed])
        XCTAssertEqual(second.shown, [], "a second surface is shown nothing")
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [])
    }

    /// Fixed in #1824; this test pinned the defect until then: a second
    /// seeded request before the first was shown (two mailto links in quick
    /// succession, or one arriving while an iPhone compose sheet is up)
    /// replaced the waiting seed, so the first message was never composed.
    /// Now both wait, and open in order as the sheet closes.
    func testASecondSeedWaitsBehindTheFirst() {
        let appState = AppState()
        let sheet = RecordingComposeSurface(window: windowA, isSheet: true).register(with: appState.compose)
        let typing = Draft(subject: "being typed")
        let first = Draft(subject: "first")
        let second = Draft(subject: "second")
        appState.compose.open(seed: typing, from: windowA)
        appState.compose.open(seed: first, from: windowA)
        appState.compose.open(seed: second, from: windowA)
        XCTAssertEqual(sheet.shown, [typing], "the sheet is up")
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowA), [first, second])

        sheet.free(in: appState.compose)
        XCTAssertEqual(sheet.shown, [typing, first])
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowA), [second])

        sheet.free(in: appState.compose)
        XCTAssertEqual(sheet.shown, [typing, first, second], "neither is lost")
    }

    func testForwardedAttachmentsAreTakenExactlyOncePerDraft() {
        let appState = AppState()
        let forwarded = Draft(subject: "Fwd: report")
        let other = Draft(subject: "Fwd: photo")
        let report = Attachment(filename: "report.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let photo = Attachment(filename: "photo.jpg", mimeType: "image/jpeg", data: Data([4]))
        appState.compose.open(seed: forwarded, attachments: [report], from: windowA)
        appState.compose.open(seed: other, attachments: [photo], from: windowA)

        XCTAssertEqual(appState.compose.takeAttachments(for: forwarded.id), [report])
        XCTAssertEqual(appState.compose.takeAttachments(for: forwarded.id), [], "a restored scene composes without")
        XCTAssertEqual(appState.compose.takeAttachments(for: other.id), [photo], "each draft keeps its own")
        XCTAssertEqual(appState.compose.takeAttachments(for: UUID()), [], "an unknown draft gets nothing")
        XCTAssertEqual(
            appState.compose.seedsWaiting(for: nil), [forwarded, other], "taking them shows no composer"
        )
    }

    func testOpeningADraftAgainReplacesItsAttachments() {
        let appState = AppState()
        let draft = Draft(subject: "Fwd")
        let old = Attachment(filename: "old.txt", mimeType: "text/plain", data: Data([1]))
        let new = Attachment(filename: "new.txt", mimeType: "text/plain", data: Data([2]))
        appState.compose.open(seed: draft, attachments: [old], from: windowA)
        appState.compose.open(seed: draft, attachments: [new], from: windowA)

        XCTAssertEqual(appState.compose.takeAttachments(for: draft.id), [new])
    }

    /// The mailto handler (`AppRootLifecycle`) passes
    /// `appState.lastActiveMainWindow` as the compose's window. Only the
    /// coordinator's half is pinned here: the test restates that argument
    /// rather than running the handler, which is view code, so a handler
    /// that changed its target would not fail it.
    func testAMailtoComposeReachesOnlyTheMainWindowLastInFront() {
        let appState = AppState()
        let surfaceA = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let surfaceB = RecordingComposeSurface(window: windowB).register(with: appState.compose)
        appState.noteActiveMainWindow(windowA)
        let seed = Draft(subject: "mailto")

        appState.compose.open(seed: seed, from: appState.lastActiveMainWindow)

        XCTAssertEqual(surfaceA.shown, [seed])
        XCTAssertEqual(surfaceB.shown, [])
    }

    /// Fixed in #1824; this test pinned the defect until then: with no main
    /// window recorded (none has come to the front yet, or the last one
    /// closed) a mailto compose aimed at no window, so every window's router
    /// answered. The first took the seed and the others opened blank
    /// drafts. Now one window opens it, the one opened last, and no other
    /// is asked. As above, the handler's argument is restated, not run.
    func testAMailtoComposeWithNoWindowRecordedOpensInOneWindow() {
        let appState = AppState()
        let surfaceA = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let surfaceB = RecordingComposeSurface(window: windowB).register(with: appState.compose)
        appState.noteActiveMainWindow(windowA)
        appState.forgetMainWindow(windowA)
        XCTAssertNil(appState.lastActiveMainWindow)
        let seed = Draft(subject: "mailto")

        appState.compose.open(seed: seed, from: appState.lastActiveMainWindow)

        XCTAssertEqual(surfaceB.shown, [seed], "the window opened last")
        XCTAssertEqual(surfaceA.shown, [], "no second composer, blank or otherwise")
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [])
    }

    // MARK: - T4: data-change reloads

    func testSidebarMarkAllReadReloadsEveryListAndLeavesAnAimedCommandAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(4)])
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Projects", unread: 4, total: 20)
        let model = FolderListViewModel(client: try TestFixtures.makeClient(imap: imap), mailStore: appState.mailStore)
        let compose = composeWaiting(for: windowA, in: appState)
        let before = appState.mailStore.listRefreshTick

        await model.markAllRead(folderPath: "Projects")

        XCTAssertEqual(appState.mailStore.listRefreshTick, before + 1, "exactly one reload")
        assertStillWaiting(compose, for: windowA, in: appState, "the compose stays aimed at A (#1824)")
        let calls = await imap.markFolderReadCalls
        XCTAssertEqual(calls, ["Projects"])
        XCTAssertNil(model.errorMessage)
    }

    /// Mailbox > Mark All as Read (Option-Command-T) goes to one window; its
    /// confirmation's reload is no window command, so every list reloads.
    func testAnAimedMarkFolderReadEndsInAReloadOfEveryList() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(2)])
        let appState = AppState()
        let model = try TestFixtures.makeModel(
            imap: imap, envelopes: [], folderPath: "Sent", mailStore: appState.mailStore
        )
        let commandsA = WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
        let commandsB = WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
        commandsA.send(.markFolderRead)

        await model.markAllRead()

        XCTAssertEqual(commandsA.count(of: .markFolderRead), 1)
        XCTAssertEqual(appState.mailStore.listRefreshTick, 1)
        XCTAssertEqual(commandsB.count(of: .markFolderRead), 0)
        XCTAssertNil(model.errorMessage)
    }

    func testEmptyTrashZeroesTrashAndReloadsEveryList() async throws {
        let imap = FakeImapClient()
        await imap.scriptEmptyTrashResults([.success(())])
        let client = try TestFixtures.makeClient(imap: imap)
        try await client.envelopeCache.store(trashSnapshot(), for: FolderTree.trashPath)
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Trash", unread: 3, total: 10)
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)
        let compose = composeWaiting(for: windowA, in: appState)
        let before = appState.mailStore.listRefreshTick

        await model.emptyTrash()

        let calls = await imap.emptyTrashCalls
        XCTAssertEqual(calls, ["Trash"])
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Trash"], 0)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["Trash"], 0)
        let snapshot = await client.envelopeCache.snapshot(for: "Trash")
        XCTAssertNil(snapshot, "the cached Trash rows are dropped")
        XCTAssertEqual(appState.mailStore.listRefreshTick, before + 1, "exactly one reload")
        assertStillWaiting(compose, for: windowA, in: appState, "the compose stays aimed at A (#1824)")
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedEmptyTrashLeavesTrashTheReloadAndTheTargetAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptEmptyTrashResults([.failure(CabalmailError.network("offline"))])
        let client = try TestFixtures.makeClient(imap: imap)
        try await client.envelopeCache.store(trashSnapshot(), for: FolderTree.trashPath)
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "Trash", unread: 3, total: 10)
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)
        let compose = composeWaiting(for: windowA, in: appState)

        await model.emptyTrash()

        let calls = await imap.emptyTrashCalls
        XCTAssertEqual(calls, ["Trash"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Trash"], 3)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["Trash"], 10)
        let snapshot = await client.envelopeCache.snapshot(for: "Trash")
        XCTAssertEqual(snapshot?.envelopes.count, 2)
        XCTAssertEqual(appState.mailStore.listRefreshTick, 0)
        assertStillWaiting(compose, for: windowA, in: appState, "the compose's target still stands")
    }

    /// A compose request waiting for `window`, whose compose sheet is up:
    /// the request a data-change reload must leave where it is.
    private func composeWaiting(for window: UUID, in appState: AppState) -> Draft {
        RecordingComposeSurface(window: window, isSheet: true).register(with: appState.compose).isBusy = true
        let seed = Draft(subject: "waiting")
        appState.compose.open(seed: seed, from: window)
        return seed
    }

    private func assertStillWaiting(
        _ seed: Draft, for window: UUID, in appState: AppState, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(appState.compose.seedsWaiting(for: window), [seed], message, file: file, line: line)
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowB), [], message, file: file, line: line)
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [], message, file: file, line: line)
    }

    private func trashSnapshot() -> EnvelopeCache.Snapshot {
        EnvelopeCache.Snapshot(
            uidValidity: 1,
            uidNext: 3,
            envelopes: [1: TestFixtures.makeEnvelope(uid: 1), 2: TestFixtures.makeEnvelope(uid: 2)]
        )
    }
}
