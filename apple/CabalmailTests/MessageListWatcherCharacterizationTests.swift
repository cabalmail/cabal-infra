import XCTest
import CabalmailKit
@testable import Cabalmail

// Characterization suite for workstream 0.8: pins how `MessageListViewModel`
// drives `MailboxWatcher` today (`startWatching`, `stopWatching`,
// `handleWatcherChanged`), so the CabalmailUI move, the AppState split and
// the mail store layer show any change to it explicitly. Some pins describe
// weaknesses; those tests say so. The teardown half (W3) lives in
// MessageListWatcherTeardownCharacterizationTests.swift and shares the
// harness below.
//
// It protects:
// - the change-driven auto-refresh from the Phase 7 client (52b4c039): one
//   change stream per folder list and none on the global search surface
//   (32f398c5). Every `.changed` tick runs the ordinary `refresh()`, which
//   leaves a trimmed deep window in place (64794213) and re-runs an active
//   pill search instead of asking for STATUS.
// - the Phase 7 reconnect as the list sees it: a failed stream is reopened
//   and the list keeps refreshing through it. #1797's open-failure backoff
//   (b039d2d6) is pinned in the Kit's MailboxWatcherTests, not here.
//
// The 1 s burst coalescing in `handleWatcherChanged` reads the wall clock
// through no seam, so it is not pinned here (W4). It still shapes these
// tests: each drives at most one watcher refresh per model, because a
// second event inside a second of the first is dropped.
//
// Every test scripts the fake's idle stream before a watcher starts (an
// unscripted one ends at once, leaving the watcher in its real-sleep
// reconnect loop), and teardown stops every model's watcher. Waits on the
// fake go through `arrive`, which fails the test at waitUntil's ceiling
// rather than hanging when a refactor moves the call being waited for.

// MARK: - Harness

/// One test's world: the fake transport, clients caching under a temp
/// directory removed at teardown, and every list model built, for teardown.
@MainActor
final class ListWatcherHarness {
    static let inbox = Folder(path: "INBOX", attributes: [], isSubscribed: true)

    let imap = FakeImapClient()
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("list-watcher-characterization-\(UUID().uuidString)")
    private var models: [MessageListViewModel] = []

    /// A list over `scope` holding `uids`, with the folder total set to
    /// match: the state a list is in once its first load has landed.
    func makeModel(
        scope: MessageListScope = .folder(inbox),
        uids: [UInt32] = [5, 4, 3, 2, 1]
    ) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            scope: scope,
            client: try makeClient(),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: AppState()
        )
        model.envelopes = Self.rows(uids)
        model.totalMessages = UInt32(uids.count)
        models.append(model)
        return model
    }

    static func rows(_ uids: [UInt32]) -> [Envelope] {
        uids.map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) }
    }

    /// A folder of `count` messages in server order. UID `count` is newest,
    /// which matches the client's UID-descending order for undated rows.
    static func folder(of count: Int) -> [Envelope] {
        rows((1...count).reversed().map { UInt32($0) })
    }

    static let thousand = folder(of: 1000)

    /// A list showing `window` of `thousand`, as paging leaves it. This is
    /// the one place these tests set the window internals by hand.
    func makeWindowModel(window: Range<Int>) throws -> MessageListViewModel {
        let model = try makeModel(uids: [])
        model.envelopes = Array(Self.thousand[window])
        model.windowStart = UInt32(window.lowerBound)
        model.hasTrimmedFront = window.lowerBound > 0
        model.totalMessages = 1000
        return model
    }

    /// STATUS for a folder of `messages`, all of them read, so the INBOX badge
    /// that a list refresh publishes stays at 0 in the test host.
    static func status(messages: Int) -> FolderStatus {
        FolderStatus(messages: messages, unseen: 0, flagged: 0, uidValidity: 7, uidNext: UInt32(messages + 1))
    }

    /// The server after one new message: STATUS counts 6, top page 6...1.
    func scriptNewMessage() async {
        await imap.scriptInitialLoad(status: Self.status(messages: 6), topEnvelopes: Self.rows([6, 5, 4, 3, 2, 1]))
    }

    /// Returns once `idle(folder:)` has been called `count` times in all.
    func awaitStreams(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async throws {
        let imap = self.imap
        try await arrive(file: file, line: line) { await imap.idleFolders.count >= count }
    }

    /// Emits `kind` on INBOX with the next STATUS held, and returns once that
    /// STATUS is parked: proof the event started a refresh.
    func emitAndCatchRefresh(
        _ kind: IdleEvent.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let imap = self.imap
        let sent = await imap.statusCalls.count
        await imap.holdNext(.status)
        await imap.emitIdle(kind)
        try await arrive(file: file, line: line) { await imap.statusCalls.count > sent }
        await imap.awaitHeld(.status)
    }

    /// Returns once the list's first positional page is parked at the hold.
    func catchHeldPage(file: StaticString = #filePath, line: UInt = #line) async throws {
        let imap = self.imap
        try await arrive(file: file, line: line) { await imap.envelopesCalls.count >= 1 }
        await imap.awaitHeld(.envelopes)
    }

    /// `waitUntil`, then ends the test if `condition` never held, so a wait
    /// on the fake that follows fails here instead of hanging.
    func arrive(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await waitUntil(file: file, line: line, condition)
        guard await condition() else { throw NeverArrived() }
    }

    func tearDown() async {
        for model in models { await model.stopWatching() }
        models = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeClient() throws -> CabalmailClient {
        let config = TestFixtures.makeConfiguration()
        let auth = NullAuthService()
        let dir = root.appendingPathComponent(UUID().uuidString)
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: URLSessionApiClient(configuration: config, authService: auth, transport: NullHTTPTransport()),
            imapClient: imap,
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: dir.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: dir.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: dir.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: dir.appendingPathComponent("outbox"))
        )
    }
}

/// Thrown by `arrive` when the awaited call never reached the fake.
private struct NeverArrived: Error {}

// MARK: - Start and change events (W1, W2)

@MainActor
final class MessageListWatcherCharacterizationTests: XCTestCase {
    private var harness: ListWatcherHarness!

    override func setUp() async throws {
        harness = ListWatcherHarness()
        await harness.imap.scriptIdle()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
    }

    /// Two overlapping calls and a later third open one stream. The watcher
    /// is recorded before `startWatching` first suspends, so the overlapping
    /// call already finds it. The "one" is read after a refresh's round trip
    /// through the stream, by which time a second watcher's open would have
    /// landed; nothing orders it more strictly than that.
    func testStartWatchingOpensOneStreamEvenWhenCalledConcurrentlyOrAgain() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()

        async let first: Void = model.startWatching()
        async let second: Void = model.startWatching()
        _ = await (first, second)
        await model.startWatching()
        try await harness.awaitStreams()
        try await harness.emitAndCatchRefresh(.exists(6))

        let opened = await imap.idleFolders
        XCTAssertEqual(opened, ["INBOX"], "one stream, on the list's own folder")
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { model.envelopes.count == 6 && !model.isLoading }
    }

    /// The global search surface has no folder to watch (32f398c5). Its
    /// stream count is read after a folder list, started later against the
    /// same transport, has opened its stream and refreshed through it.
    func testTheSearchSurfaceNeverOpensAStream() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let search = try harness.makeModel(scope: .search, uids: [])
        let inbox = try harness.makeModel()

        await search.startWatching()
        await inbox.startWatching()
        try await harness.awaitStreams()
        try await harness.emitAndCatchRefresh(.exists(6))

        let opened = await imap.idleFolders
        XCTAssertEqual(opened, ["INBOX"], "only the folder list opened a stream")
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { inbox.envelopes.count == 6 && !inbox.isLoading }
    }

    /// A new-mail event runs the ordinary refresh: STATUS with the flagged
    /// count, then the top page, merged on top of the loaded rows.
    func testANewMessageEventRefreshesTheListAndMergesTheNewRow() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()

        try await harness.emitAndCatchRefresh(.exists(6))
        XCTAssertTrue(model.isLoading, "the list reads as loading while STATUS is out")
        XCTAssertEqual(model.envelopes.map(\.uid), [5, 4, 3, 2, 1], "nothing moves before the server answers")
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }

        XCTAssertEqual(model.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(model.totalMessages, 6)
        XCTAssertNil(model.errorMessage)
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls, [.init(path: "INBOX", flagged: true)])
        let topCalls = await imap.topEnvelopesCalls
        XCTAssertEqual(topCalls, [.init(folder: "INBOX", limit: 50, totalMessages: 6, sort: .default)])
        let snapshot = await model.client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertEqual(snapshot.map { Set($0.envelopes.keys) }, Set<UInt32>(1...6), "the new row is cached too")
    }

    /// The production stream reports a shrunken folder as `.expunge(0)`. The
    /// watcher maps it to the same `.changed` tick, so it starts the same
    /// refresh. What that refresh prunes belongs to the refresh path, not to
    /// the watcher, and is not pinned here.
    func testAnExpungeEventStartsTheSameRefresh() async throws {
        let imap = harness.imap
        await imap.scriptInitialLoad(
            status: ListWatcherHarness.status(messages: 4),
            topEnvelopes: ListWatcherHarness.rows([5, 4, 2, 1])
        )
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()

        try await harness.emitAndCatchRefresh(.expunge(0))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }

        XCTAssertEqual(model.totalMessages, 4)
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls, [.init(path: "INBOX", flagged: true)])
        let topCalls = await imap.topEnvelopesCalls
        XCTAssertEqual(topCalls.map(\.totalMessages), [4])
    }

    /// The event runs `refresh()`, not `hardReload()`. On a list scrolled deep
    /// enough that its front was trimmed, that refresh updates the count but
    /// fetches no top page and leaves the rows where they are (64794213).
    ///
    /// Pins current behaviour, which looks like a defect: `windowStart` is
    /// not shifted when the total changes, so the deep window is one row off
    /// against the server's positions. The new message took index 0, so the
    /// server's index 300 now holds UID 701 while the list still shows 700
    /// there. Scrolling back up loads indices 100..<300 (UIDs 901...702), and
    /// UID 701 is never fetched.
    /// Tracked in #1818.
    func testAnEventOnADeepScrolledListMovesOnlyTheCountSoScrollingUpSkipsARow() async throws {
        let imap = harness.imap
        await imap.scriptInitialLoad(status: ListWatcherHarness.status(messages: 1001), topEnvelopes: [])
        await imap.scriptFolderContents(ListWatcherHarness.folder(of: 1001))
        let model = try harness.makeWindowModel(window: 300..<600)
        await model.startWatching()
        try await harness.awaitStreams()

        try await harness.emitAndCatchRefresh(.exists(1001))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }

        XCTAssertEqual(model.totalMessages, 1001)
        XCTAssertEqual(model.windowStart, 300, "the start stays put although every index moved down one")
        XCTAssertEqual(model.envelopes.count, 300)
        XCTAssertEqual(model.envelope(at: 300)?.uid, 700)
        XCTAssertNil(model.errorMessage)
        let topCalls = await imap.topEnvelopesCalls
        XCTAssertTrue(topCalls.isEmpty, "no top page while the front is trimmed")

        model.ensureLoaded(around: 300)
        let previous = try XCTUnwrap(model.loadPrevTask)
        await previous.value
        let calls = await imap.envelopesCalls
        XCTAssertEqual(calls, [.init(folder: "INBOX", offset: 100, limit: 200, sort: .default)])
        XCTAssertEqual(model.windowStart, 100)
        XCTAssertEqual(model.envelope(at: 299)?.uid, 702)
        XCTAssertEqual(model.envelope(at: 300)?.uid, 700, "the server holds UID 701 at index 300")
        XCTAssertFalse(model.envelopes.contains { $0.uid == 701 }, "UID 701 is never loaded")
    }

    /// Pins current behaviour, which looks like a defect: while the Unread or
    /// Flagged pill is showing, a change event re-runs the pill's search and
    /// sends no STATUS. The pill counts and this list's push to the sidebar
    /// badge (#1064) stay where they were until something else moves them:
    /// an optimistic delta, a manual sidebar refresh, or (for the app icon
    /// only) AppState's 60 s badge poller.
    ///
    /// The absence is read once the re-run search has landed. Today the
    /// refresh returns right there, which orders the read; a STATUS added
    /// after the search would race it.
    /// Tracked in #1819.
    func testAnEventWhileAPillIsActiveRerunsTheSearchAndLeavesTheCountsStale() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        await imap.scriptSearch(SearchResult(
            envelopes: [SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 4), folder: "INBOX")],
            totalEstimate: 1,
            nextCursor: nil,
            foldersSearched: ["INBOX"],
            truncated: false
        ))
        let model = try harness.makeModel()
        await model.applyFilter(.unread)
        XCTAssertTrue(model.isSearchActive)
        model.unseen = 3
        await model.startWatching()
        try await harness.awaitStreams()

        await imap.holdNextSearch()
        await imap.emitIdle(.exists(6))
        try await harness.arrive { await imap.searchCalls.count >= 2 }
        await imap.awaitHeldSearch()
        let searches = await imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the pill's own search, then the event's re-run")
        XCTAssertEqual(searches.last?.unread, true)
        XCTAssertEqual(searches.last?.folder, "INBOX")
        await imap.releaseHeldSearch()
        try await waitUntilOnMainActor { !model.isLoading }

        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty, "no STATUS, so no fresh counts")
        XCTAssertEqual(model.unseen, 3, "the scripted STATUS would have said 0")
        XCTAssertEqual(model.totalMessages, 5, "the scripted STATUS would have said 6")
        XCTAssertNil(model.appState.folderUnreadCounts["INBOX"], "nothing is pushed to the sidebar badge")
        XCTAssertEqual(model.envelopes.map(\.uid), [4])
        XCTAssertEqual(model.filterTab, .unread)
    }

    /// The Phase 7 reconnect (52b4c039) as the list sees it: a stream that
    /// fails mid-flight is reopened on the same folder, and the list's
    /// consumer keeps refreshing across the watcher's `.reconnecting` and
    /// `.active` events. The list builds its watcher with the default 2 s
    /// backoff on the real clock, so this test spends that long. The
    /// open-failure backoff of #1797 is pinned in the Kit's
    /// `MailboxWatcherTests.testWatcherOverTheApiBackedClientBacksOffWhileOffline`.
    func testAFailedStreamIsReopenedOnTheSameFolderAndStillRefreshes() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams()

        await imap.finishIdle(throwing: CabalmailError.network("offline"))
        try await harness.awaitStreams(2)
        let opened = await imap.idleFolders
        XCTAssertEqual(opened, ["INBOX", "INBOX"])

        try await harness.emitAndCatchRefresh(.exists(6))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !model.isLoading }
        XCTAssertEqual(model.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
    }
}
