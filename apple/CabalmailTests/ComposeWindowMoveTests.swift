import XCTest
import CabalmailKit
@testable import CabalmailUI

/// "Open in New Window" from a compose sheet (`ComposeWindowMove`), window
/// first and sheet last: the window is asked for at the tap and the draft
/// follows it. Until the window claims the draft the sheet is frozen, writes
/// nothing and can take its draft back; once it has, the sheet goes without
/// doing anything a closing composer does, because the draft is still being
/// written, in the window. A move no window claims leaves the sheet as it
/// was.
@MainActor
final class ComposeWindowMoveTests: XCTestCase {
    // MARK: Claimed

    func testAClaimedMoveLeavesNoServerCallAndKeepsTheLocalDraft() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }
        let move = ComposeWindowMove()

        await move.move(sheet, along: router.route)?.value

        XCTAssertTrue(router.sheetClosed)
        let calls = await transport.calls
        XCTAssertEqual(calls, [], "no send, save or discard: the window carries the draft on")
        let kept = try await sheet.draftStore.load(id: sheet.draftId)
        XCTAssertEqual(kept?.subject, "moving probe")
        XCTAssertFalse(sheet.autosave.isRunning)
        XCTAssertTrue(sheet.serverDraftQueue.isClosed, "the sheet writes no server copy again")
        XCTAssertTrue(sheet.isMovingToWindow, "the leaving sheet takes no Send, Cancel or Discard")
        XCTAssertTrue(move.isMoving, "frozen while it leaves")

        let window = try XCTUnwrap(router.windows.first)
        try await waitUntilOnMainActor { window.autosave.isRunning }
        XCTAssertEqual(window.draftId, sheet.draftId)
        XCTAssertEqual(window.serverDraftRef, DraftServerRef(uid: 785, uidValidity: 9))
    }

    func testAClaimedMoveReleasesTheLockAndOpensTheWaitingLink() async throws {
        let suiteName = "ComposeWindowMoveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = NavStateCoordinator(
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            clientID: "this-install",
            store: ResumeSessionStore(defaults: defaults)
        )
        let links = DeepLinkRouter()
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail, deepLinks: links)
        let router = SheetRouter(navigator: navigator)
        router.windowComes = true
        defer { router.stopWindows() }
        navigator.windowID = router.origin
        links.register(navigator)
        navigator.composeLock.isUp = true
        links.open(.message(NavState(folder: "Archive", uid: 7, clientID: "push")), in: router.origin)
        XCTAssertNil(navigator.selectedFolder, "the link waits for the sheet")

        let sheet = try await TestFixtures.makeMovableComposeModel()
        await ComposeWindowMove().move(sheet, along: router.route)?.value

        XCTAssertTrue(router.sheetClosed)
        XCTAssertFalse(navigator.composeLock.isUp, "released at the claim, not when the sheet's dismissal lands")
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
    }

    func testTheMovedWindowKnowsItsOrigin() async throws {
        let sheet = try await TestFixtures.makeMovableComposeModel()
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }

        await ComposeWindowMove().move(sheet, along: router.route)?.value

        let slot = try XCTUnwrap(router.opened.first)
        XCTAssertEqual(router.compose.origin(of: slot), router.origin, "closing the window returns to this one")
        XCTAssertEqual(router.compose.slots.seed(for: slot)?.id, sheet.draftId)
        XCTAssertEqual(router.compose.slots.openCount, 1)
    }

    // MARK: Refused

    func testAnUnclaimedMoveLeavesTheSheetAsItWas() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        sheet.autosave.start(for: sheet)
        defer { sheet.stop() }
        // The deadline passes at once, and no window comes.
        let router = SheetRouter(handoffs: ComposeHandoffs(sleep: { _ in }))
        let move = ComposeWindowMove()

        await move.move(sheet, along: router.route)?.value

        XCTAssertEqual(router.opened.count, 1)
        XCTAssertFalse(router.sheetClosed)
        XCTAssertEqual(move.phase, .refused)
        XCTAssertFalse(sheet.isMovingToWindow)
        XCTAssertTrue(sheet.autosave.isRunning)
        XCTAssertFalse(sheet.serverDraftQueue.isClosed)
        XCTAssertEqual(sheet.errorMessage, ComposeWindowMove.refusedMessage)
        XCTAssertEqual(sheet.subject, "moving probe")
        XCTAssertEqual(sheet.toText, "someone@example.com")
        XCTAssertEqual(sheet.serverDraftRef, DraftServerRef(uid: 785, uidValidity: 9))
        XCTAssertTrue(sheet.canSend)

        await move.move(sheet, along: router.route)?.value
        XCTAssertEqual(router.opened.count, 1, "a refused sheet offers no second move")

        // The session is open again: the next autosave tick reaches the server.
        await sheet.autosaveToServer()
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save])
    }

    /// The snapshot is read through the checked bridge; a rich pane that
    /// cannot be read leaves the draft where it is. The window has opened
    /// by then, at the tap: it composes nothing of the draft, and closes
    /// once in front, saving nothing. The broken read answers something
    /// other than text rather than throwing, so no page error raises the
    /// dead-editor banner over the one under test.
    func testAMoveWhoseSnapshotFailsLeavesTheSheetAsItWasAndClosesTheWindow() async throws {
        let sheet = try await TestFixtures.makeMovableComposeModel()
        _ = try await sheet.editorController.webView.evaluateJavaScript(
            "window.cabal.getHTML = function () { return 42; }; true"
        )
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }
        let move = ComposeWindowMove()

        await move.move(sheet, along: router.route)?.value

        XCTAssertEqual(router.opened.count, 1, "the window opens at the tap, before the draft is read")
        XCTAssertEqual(move.phase, .refused)
        XCTAssertFalse(router.sheetClosed)
        XCTAssertFalse(sheet.isMovingToWindow)
        XCTAssertFalse(sheet.serverDraftQueue.isClosed)
        XCTAssertTrue(sheet.autosave.isRunning)
        XCTAssertEqual(sheet.errorMessage, ComposeWindowMove.refusedMessage)
        XCTAssertEqual(sheet.subject, "moving probe")
        sheet.stop()

        try await waitUntilOnMainActor { router.windowsClosed == 1 }
        let window = try XCTUnwrap(router.windows.first)
        XCTAssertEqual(window.subject, "", "the window composed a draft the sheet kept")
        XCTAssertFalse(window.autosave.isRunning)
        let written = try await window.draftStore.load(id: window.draftId)
        XCTAssertNil(written)
    }

    // MARK: Ordering

    /// The snapshot is taken behind a save already on the wire, so the window
    /// replaces the copy that save landed rather than adding a second. The
    /// window opens at the tap all the same, and waits for the draft
    /// without building a composer.
    func testAMoveWaitsForAnInFlightSaveAndHandsOverItsUID() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }
        await transport.holdNextSave()
        let save = Task { await sheet.autosaveToServer() }
        await transport.waitUntilSaveStarted()

        let moving = ComposeWindowMove().move(sheet, along: router.route)
        XCTAssertEqual(router.opened.count, 1, "the window waited for the save to open")
        let sentDuringTheSave = await holdsOnMainActor(within: 0.3) {
            !router.compose.handoffs.awaitsSnapshot(for: sheet.draftId)
        }
        XCTAssertFalse(sentDuringTheSave, "the draft must not follow the window while a /save_draft is outstanding")
        XCTAssertEqual(router.windows.count, 0, "the window built a composer before its draft came")

        await transport.releaseHeldSave()
        await save.value
        await moving?.value

        XCTAssertTrue(router.sheetClosed)
        let window = try XCTUnwrap(router.windows.first)
        XCTAssertEqual(window.serverDraftRef?.uid, 786)
        XCTAssertEqual(window.replacedServerDraftUIDs, [785])
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.kind), [.save])
    }

    func testSendCancelDiscardDoNothingWhileMoving() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        let deadline = Gate()
        let router = SheetRouter(handoffs: ComposeHandoffs(sleep: { _ in await deadline.wait() }))
        let move = ComposeWindowMove()
        let moving = move.move(sheet, along: router.route)
        // The window opened at the tap; wait for the draft to follow it, past
        // the sheet's last local flush.
        try await waitUntilOnMainActor { !router.compose.handoffs.awaitsSnapshot(for: sheet.draftId) }
        XCTAssertFalse(sheet.canSend)
        XCTAssertFalse(sheet.mayHandOff)

        let sent = await sheet.send()
        let cancelled = await sheet.cancel()
        await sheet.discard()

        XCTAssertFalse(sent)
        XCTAssertFalse(cancelled)
        let calls = await transport.calls
        XCTAssertEqual(calls, [])
        let kept = try await sheet.draftStore.load(id: sheet.draftId)
        XCTAssertNotNil(kept, "Discard removed the local copy mid-move")
        XCTAssertNil(sheet.errorMessage, "a refused Send says nothing while the sheet is frozen")

        deadline.open()
        await moving?.value
        XCTAssertEqual(move.phase, .refused)
        sheet.stop()
    }

    /// The other direction: no move starts while the draft is on its way out.
    /// Each move runs in a task: one that wrongly started would wait behind
    /// the held request, which the test releases only afterwards.
    func testNoMoveStartsWhileTheDraftIsBeingSentOrClosed() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        // A move that wrongly started is refused at once rather than at the
        // end of a long deadline.
        let router = SheetRouter(handoffs: ComposeHandoffs(sleep: { _ in }))

        await transport.holdNextSend()
        let sending = Task { await sheet.send() }
        await transport.waitUntilSendStarted()
        XCTAssertFalse(sheet.mayHandOff)
        let moveWhileSending = ComposeWindowMove()
        let movingWhileSending = Task { await moveWhileSending.move(sheet, along: router.route)?.value }
        let startedWhileSending = await holdsOnMainActor(within: 0.3) { moveWhileSending.phase != .idle }
        XCTAssertFalse(startedWhileSending, "a move started while the draft was being sent")
        await transport.releaseHeldSend()
        _ = await sending.value
        await movingWhileSending.value

        let closing = try await TestFixtures.makeMovableComposeModel(transport: transport)
        await transport.holdNextSave()
        let cancelling = Task { await closing.cancel() }
        await transport.waitUntilSaveStarted()
        XCTAssertFalse(closing.mayHandOff)
        let moveWhileClosing = ComposeWindowMove()
        let movingWhileClosing = Task { await moveWhileClosing.move(closing, along: router.route)?.value }
        let startedWhileClosing = await holdsOnMainActor(within: 0.3) { moveWhileClosing.phase != .idle }
        XCTAssertFalse(startedWhileClosing, "a move started while the draft was being closed")
        await transport.releaseHeldSave()
        _ = await cancelling.value
        await movingWhileClosing.value
        XCTAssertEqual(router.opened, [])
    }

    /// Nor before the composer has started: the snapshot would read a rich
    /// pane not yet seeded, and hand a reply over without its quote.
    func testNoMoveStartsBeforeTheComposerHasStarted() async throws {
        let sheet = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Re: plans", body: "> quoted", composeIntent: .reply)
        )
        try await TestFixtures.requireEditorBridge(sheet)
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }
        let move = ComposeWindowMove()
        let starting = Task { await sheet.start() }
        XCTAssertFalse(sheet.mayHandOff, "offered before the rich pane was seeded")

        await move.move(sheet, along: router.route)?.value

        XCTAssertEqual(router.opened, [])
        XCTAssertEqual(move.phase, .idle)
        await starting.value
        sheet.stop()
        // As `ComposeView` does once it has given the first focus.
        sheet.hasStarted = true
        XCTAssertTrue(sheet.mayHandOff)
    }
}

/// When a move asks for the window, and when its deadline starts: both at
/// the tap, before the sheet has read its draft (`ComposeWindowMove.move`).
@MainActor
final class ComposeWindowMoveTapTests: XCTestCase {
    /// The window is asked for in the tap's own turn, before the sheet has
    /// flushed or read its draft, and the draft follows it: asked for after
    /// those awaits, it opened on an iPad simulator but never came in front
    /// to claim the draft. The tap is the offer the router puts on the
    /// sheet, so a task put between the button and the move fails here as
    /// well as one put inside the move. Nothing between the tap and the
    /// first four assertions awaits, so what they see ran before the move's
    /// first await.
    func testTheWindowOpensInTheTapsOwnTurnAndTheDraftFollows() async throws {
        let sheet = try await TestFixtures.makeMovableComposeModel()
        sheet.autosave.start(for: sheet)
        defer { sheet.stop() }
        let router = SheetRouter()
        router.windowComes = true
        defer { router.stopWindows() }
        let offer = ComposeWindowOffer.moving(with: ComposeWindowMove(), along: router.route)

        offer.open(sheet)

        XCTAssertEqual(router.events, [.openedWindow])
        XCTAssertTrue(
            router.compose.handoffs.awaitsSnapshot(for: sheet.draftId),
            "the window opened with no hand-off to wait for"
        )
        XCTAssertTrue(sheet.isMovingToWindow, "the sheet was not frozen at the tap")
        XCTAssertFalse(sheet.autosave.isRunning, "the sheet's autosaves ran on past the tap")
        try await waitUntilOnMainActor { router.sheetClosed }
        XCTAssertEqual(router.events, [.openedWindow, .draftReachedWindow, .closedSheet])
    }

    /// The deadline runs from the tap and covers the whole move: a draft
    /// still being read when it passes stays in the sheet, and the window
    /// that opened for it closes, saving nothing.
    func testTheDeadlineRunsFromTheTap() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        let sheet = try await TestFixtures.makeMovableComposeModel(transport: transport)
        var asked: [Duration] = []
        let deadline = Gate()
        let router = SheetRouter(handoffs: ComposeHandoffs(sleep: {
            asked.append($0)
            await deadline.wait()
        }))
        router.windowComes = true
        defer { router.stopWindows() }
        // The read waits behind a save on the wire.
        await transport.holdNextSave()
        let save = Task { await sheet.autosaveToServer() }
        await transport.waitUntilSaveStarted()
        let move = ComposeWindowMove()

        let moving = move.move(sheet, along: router.route)
        // The deadline is asked for while the save is still held, so before
        // the sheet can have read its draft: it runs from the tap.
        try await waitUntilOnMainActor { asked == [ComposeWindowMove.deadline] }
        XCTAssertTrue(
            router.compose.handoffs.awaitsSnapshot(for: sheet.draftId),
            "the sheet read its draft before the save on the wire landed"
        )
        deadline.open()
        try await waitUntilOnMainActor { router.windowsClosed == 1 }
        await transport.releaseHeldSave()
        await save.value
        await moving?.value

        XCTAssertEqual(move.phase, .refused)
        XCTAssertFalse(router.sheetClosed)
        XCTAssertFalse(sheet.isMovingToWindow)
        XCTAssertEqual(sheet.errorMessage, ComposeWindowMove.refusedMessage)
        XCTAssertEqual(sheet.subject, "moving probe")
        XCTAssertEqual(router.windows.first?.subject, "", "the window composed a draft the sheet kept")
        sheet.stop()
    }
}

/// The router a move runs from in these tests: the main window the sheet
/// is over, and what the move asked of it.
@MainActor
private final class SheetRouter {
    enum Event: Equatable {
        case openedWindow
        /// A window that came built its composer from the sheet's snapshot.
        case draftReachedWindow
        case closedSheet
    }

    let compose: ComposeCoordinator
    let origin = UUID()
    let navigator: SceneNavigator
    private(set) var opened: [ComposeSlot] = []
    private(set) var sheetClosed = false
    /// What the move asked of the router, and what reached the window, in
    /// order.
    private(set) var events: [Event] = []
    /// The composers of the windows that came.
    private(set) var windows: [ComposeViewModel] = []
    /// How many of them closed.
    private(set) var windowsClosed = 0
    /// Whether a window comes for `openWindow`, in front, as
    /// `ComposeWindowContent` builds it. None comes by default, as when iOS
    /// ignores the request.
    var windowComes = false

    init(
        handoffs: ComposeHandoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline),
        navigator: SceneNavigator? = nil
    ) {
        compose = ComposeCoordinator(slots: ComposeSlotRegistry(), handoffs: handoffs)
        self.navigator = navigator ?? SceneNavigator(coordinator: { nil }, hasClient: { false })
    }

    var route: ComposeWindowMove.Route {
        ComposeWindowMove.Route(
            compose: compose,
            origin: origin,
            navigator: navigator,
            openWindow: { [self] slot in open(slot) },
            closeSheet: { [self] in
                sheetClosed = true
                events.append(.closedSheet)
            }
        )
    }

    func stopWindows() {
        windows.forEach { $0.stop() }
    }

    private func open(_ slot: ComposeSlot) {
        opened.append(slot)
        events.append(.openedWindow)
        guard windowComes, let seed = compose.slots.seed(for: slot) else { return }
        Task { await comeInFront(composing: seed.id) }
    }

    /// As `ComposeWindowContent`: no composer while the hand-off awaits the
    /// sheet's snapshot, then one built from the hand-off, in front.
    /// `ComposeWindowMoveSourceScanTests` pins that the window waits so.
    private func comeInFront(composing draftID: UUID) async {
        _ = await holdsOnMainActor(within: 30) { !compose.handoffs.awaitsSnapshot(for: draftID) }
        guard let window = try? TestFixtures.makeMovedComposeModel(
            for: draftID, from: compose.handoffs, onClose: { [weak self] in self?.windowsClosed += 1 }
        ) else { return }
        if window.handoff?.snapshot != nil { events.append(.draftReachedWindow) }
        window.handoff?.sceneIsActive = true
        windows.append(window)
        await window.start()
    }
}

/// A wait the test ends by hand: a hand-off deadline that passes only when
/// the test says so.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
