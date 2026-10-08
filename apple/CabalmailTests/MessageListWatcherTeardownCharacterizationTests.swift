import XCTest
import CabalmailKit
@testable import CabalmailUI

// Characterization suite for workstream 0.8, teardown half (W3): pins what
// `MessageListViewModel.stopWatching()` does today, so the CabalmailUI move
// and the mail store layer show any change to it explicitly. The harness and
// the start/change-event half live in
// MessageListWatcherCharacterizationTests.swift.
//
// It protects:
// - the stream's end on `.onDisappear`, and a restart on the same model
//   (52b4c039).
// - the cancel of the model-owned paging tasks (16b07580, 563c3fc6,
//   35105d26, dd885cbf) and of the debounced scroll-settle loader
//   (efccb400): each drops its page without an error.
// - a stop mid-refresh, which cancels it without an error (#1816).
//
// Not pinned:
// - `persistTask`, the 1 s envelope-snapshot debounce `stopWatching` also
//   cancels, is private and sleeps a real second, so it has no seam (like
//   W4).
// - `stopWatching` leaves `loadMoreSearchTask` running. That is not pinned
//   because nothing a test can see through the fake would change if it
//   were cancelled: the fake's search ignores cancellation and
//   `loadMoreSearchResults` checks for none, so the page merges either way.

@MainActor
final class MessageListWatcherTeardownCharacterizationTests: XCTestCase {
    private var harness: ListWatcherHarness!

    override func setUp() async throws {
        harness = ListWatcherHarness()
        await harness.imap.scriptIdle()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
    }

    /// The view calls this from `.onDisappear`. Either half of the stop ends
    /// the stream on its own (cancelling the list's task terminates the
    /// watcher through the stream's `onTermination`, and stopping the
    /// watcher cancels its runner), so this catches only the loss of both.
    /// The event emitted afterwards documents the outcome: the fake drops it
    /// once the stream has terminated, so those checks cannot fail alone.
    func testStopWatchingTerminatesTheIdleStream() async throws {
        let imap = harness.imap
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()

        await model.stopWatching()
        try await harness.arrive { await imap.idleTerminations == 1 }

        await imap.emitIdle(.exists(6))
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty)
        XCTAssertEqual(model.envelopes.map(\.uid), [5, 4, 3, 2, 1])
    }

    /// `stopWatching()` clears the watcher, so a later `startWatching()` on
    /// the same model opens a new stream on the folder, and that stream
    /// refreshes the list. The view makes that second call when the list
    /// comes back on screen with the model it kept (#1816).
    func testWatchingStartsAgainAfterAStop() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()
        await model.stopWatching()
        try await harness.arrive { await imap.idleTerminations == 1 }

        await model.startWatching()
        try await harness.awaitStreams(2)
        let opened = await imap.idleFolders
        XCTAssertEqual(opened, ["INBOX", "INBOX"])
        try await harness.emitAndCatchRefresh(.exists(6))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }
        XCTAssertEqual(model.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
    }

    /// A watcher refresh runs inside the watcher's task, so stopping the
    /// watcher cancels the refresh while it is in flight, and no top page is
    /// fetched. The cancelled STATUS leaves no "Couldn't reach the server"
    /// banner on the model the view keeps. Fixed in #1816; this test pinned
    /// the banner until then.
    func testStoppingMidRefreshCancelsItWithoutAnError() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()
        try await harness.emitAndCatchRefresh(.exists(6))

        await model.stopWatching()
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.envelopes.map(\.uid), [5, 4, 3, 2, 1])
        XCTAssertEqual(model.window.totalMessages, 5)
        let topCalls = await imap.topEnvelopesCalls
        XCTAssertTrue(topCalls.isEmpty)
    }

    // MARK: Model-owned paging tasks

    /// The 1000-message folder on the server and a list showing `window` of it.
    private func pagedModel(window: Range<Int>) async throws -> MessageListViewModel {
        await harness.imap.scriptFolderContents(ListWatcherHarness.thousand)
        return try harness.makeWindowModel(window: window)
    }

    /// 16b07580: the page is dropped without an error. The next scroll asks
    /// for it again, and that request lands.
    func testStoppingDropsAnInFlightLoadMorePage() async throws {
        let imap = harness.imap
        let model = try await pagedModel(window: 0..<50)
        await imap.holdNext(.envelopes)
        model.window.ensureLoaded(around: 0)
        let page = try XCTUnwrap(model.window.loadMoreTask)
        try await harness.catchHeldPage()

        await model.stopWatching()
        await imap.releaseHeld(.envelopes)
        await page.value

        XCTAssertEqual(model.envelopes.count, 50, "the cancelled page is not merged")
        XCTAssertFalse(model.window.isLoadingMore)
        XCTAssertNil(model.errorMessage, "paging failures stay silent")
        model.window.ensureLoaded(around: 0)
        await model.window.loadMoreTask?.value
        XCTAssertEqual(model.envelopes.count, 250)
        let calls = await imap.envelopesCalls
        XCTAssertEqual(calls.map(\.offset), [50, 50], "the same page, asked for twice")
    }

    /// 563c3fc6: the front reload is dropped, and the window stays where it was.
    func testStoppingDropsAnInFlightLoadPreviousPage() async throws {
        let imap = harness.imap
        let model = try await pagedModel(window: 300..<600)
        await imap.holdNext(.envelopes)
        model.window.ensureLoaded(around: 300)
        let page = try XCTUnwrap(model.window.loadPrevTask)
        try await harness.catchHeldPage()

        await model.stopWatching()
        await imap.releaseHeld(.envelopes)
        await page.value

        XCTAssertEqual(model.window.windowStart, 300)
        XCTAssertEqual(model.envelopes.count, 300)
        XCTAssertEqual(model.envelopes.first?.uid, 700)
        XCTAssertTrue(model.window.hasTrimmedFront)
        XCTAssertFalse(model.window.isLoadingPrevious)
        let calls = await imap.envelopesCalls
        XCTAssertEqual(calls, [.init(folder: "INBOX", offset: 100, limit: 200, sort: .default)])
    }

    /// 35105d26: an in-flight scrollbar jump is dropped; its target stays blank.
    func testStoppingDropsAnInFlightWindowJump() async throws {
        let imap = harness.imap
        let model = try await pagedModel(window: 0..<50)
        await imap.holdNext(.envelopes)
        model.window.ensureLoaded(around: 900)
        let jump = try XCTUnwrap(model.window.loadWindowTask)
        try await harness.catchHeldPage()

        await model.stopWatching()
        await imap.releaseHeld(.envelopes)
        await jump.value

        XCTAssertEqual(model.window.windowStart, 0)
        XCTAssertEqual(model.envelopes.count, 50)
        XCTAssertNil(model.window.envelope(at: 900))
        XCTAssertFalse(model.window.isLoadingWindow)
        let calls = await imap.envelopesCalls
        XCTAssertEqual(calls, [.init(folder: "INBOX", offset: 800, limit: 200, sort: .default)])
    }

    /// dd885cbf: a bottom window still in flight when the list stops is never
    /// staged, so a later jump to the bottom fetches it again.
    func testStoppingDropsAnInFlightBottomPrefetch() async throws {
        let imap = harness.imap
        let model = try await pagedModel(window: 0..<50)
        await imap.holdNext(.envelopes)
        model.window.scheduleBottomPrefetch()
        let fill = try XCTUnwrap(model.window.bottomPrefetchTask)
        try await harness.catchHeldPage()

        await model.stopWatching()
        await imap.releaseHeld(.envelopes)
        await fill.value

        model.window.ensureLoaded(around: 999)
        await model.window.loadWindowTask?.value
        XCTAssertEqual(model.window.windowStart, 800)
        XCTAssertEqual(model.window.envelope(at: 999)?.uid, 1)
        let calls = await imap.envelopesCalls
        let bottom = FakeImapClient.EnvelopesCall(folder: "INBOX", offset: 800, limit: 200, sort: .default)
        XCTAssertEqual(calls, [bottom, bottom], "the jump fetches the bottom again rather than adopting it")
    }

    /// efccb400: the debounced settle loader, armed by every row that reports
    /// in (and by PgUp/PgDown), is cancelled too, so a stop inside its
    /// 175 ms debounce loads nothing. The row it was armed for stays a
    /// placeholder until the next scroll arms the loader again. The stop
    /// runs before the test yields the main actor, so the loader cannot
    /// have passed its cancellation check first.
    func testStoppingCancelsThePendingScrollSettleLoad() async throws {
        let imap = harness.imap
        let model = try await pagedModel(window: 0..<50)
        model.window.noteRowVisible(900)
        let loader = try XCTUnwrap(model.window.keyScrollTask)

        await model.stopWatching()
        await loader.value
        await model.window.loadMoreTask?.value
        await model.window.loadWindowTask?.value

        let dropped = await imap.envelopesCalls
        XCTAssertTrue(dropped.isEmpty, "the settle load never ran")
        XCTAssertEqual(model.window.windowStart, 0)
        XCTAssertNil(model.window.envelope(at: 900))

        model.window.noteRowVisible(900)
        let rearmed = try XCTUnwrap(model.window.keyScrollTask)
        await rearmed.value
        await model.window.loadWindowTask?.value
        let calls = await imap.envelopesCalls
        XCTAssertEqual(calls, [.init(folder: "INBOX", offset: 800, limit: 200, sort: .default)])
        XCTAssertEqual(model.window.envelope(at: 900)?.uid, 100)
    }
}
