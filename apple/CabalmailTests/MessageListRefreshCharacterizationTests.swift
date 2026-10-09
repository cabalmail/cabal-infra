import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 (the CabalmailUI module split,
/// AppState split into per-window navigation and a per-account session, the
/// mail store layer, and focused-window commands replacing the integer tick
/// counters). It pins what `MessageListViewModel`'s folder refresh entry
/// points do today -- the calls the folder's poller (its change watcher and
/// 60-second tick), pull-to-refresh, the Refresh command, the sort menu and
/// the first load make -- so the refactor shows any change in behaviour
/// explicitly. What they do while a search or a pill is showing is pinned
/// in `MessageListSearchRefreshCharacterizationTests`.
///
/// Protects the background refresh's keep-the-rows catch (750dba7a, the
/// behaviour #1796 brought hardReload, setSort and clearSearch in line
/// with), #1796's probe-then-refresh shape for the sort and hard-reload
/// rebuilds, and #736 and 91b6cd4e (a cancelled caller can't fail the
/// load). A test whose name ends in `Weakness` pins a known shortcoming on
/// purpose so the refactor can flip it deliberately; it is a record, not a
/// spec. The shared set-up lives in `RefreshCharacterizationFixture.swift`.
@MainActor
final class MessageListRefreshCharacterizationTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private let subjectOrder = SortCriterion(field: .subject, direction: .ascending)

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    // MARK: - Background refresh offline

    /// `refresh()`'s catch has kept the rows on a failed background refresh
    /// since it was written (750dba7a). #1796 did not change it: it is the
    /// reference behaviour #1796 brought the Refresh command, the sort menu
    /// and leaving a search in line with. Pinned here for the counts too.
    func testOfflineBackgroundRefreshKeepsTheRowsAndCountsAndShowsTheError() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.unseen = 1
        let offline = CabalmailError.network("offline")
        await fixture.imap.scriptStatusResults([.failure(offline)])

        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertEqual(model.errorMessage, offline.localizedDescription)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.window!.totalMessages, 3)
        XCTAssertEqual(model.unseen, 1)
        let tops = await fixture.topPageCalls()
        XCTAssertTrue(tops.isEmpty, "no top page is asked for once STATUS fails")
    }

    // MARK: - Concurrency and cancellation

    /// `refresh()` is single-flight (#1820). Refreshes asked for while one is
    /// out don't go to the wire: they wait for it, then share one more pass,
    /// which asks STATUS afresh. So the first pass's page, fetched before
    /// UID 4 arrived, can no longer land after a newer one and prune UID 4
    /// from the list, the snapshot and the body cache; the rerun lands last.
    /// `isLoading` holds until the last refresh returns, so a refresh that
    /// finishes first can't reopen `ensureLoaded`'s gate under another.
    /// This test pinned the overlap until then.
    func testRefreshesAskedForWhileOneIsOutWaitAndShareOneRerunSoNewerMailStays() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        await fixture.imap.holdNext(.topEnvelopes)
        let first = Task { await model.refresh() }
        await fixture.imap.awaitHeld(.topEnvelopes)

        // UID 4 arrives, and two more refreshes are asked for.
        let second = Task { await model.refresh() }
        let third = Task { await model.refresh() }
        try await waitUntilOnMainActor { model.window!.refreshFlight.waiting == 2 }
        let waiting = await fixture.statusCalls()
        XCTAssertEqual(waiting.count, 1, "neither went to the wire")

        // The first pass's page lands as fetched, from before UID 4. The
        // rerun's STATUS is held so the server can answer with UID 4.
        await fixture.imap.holdNext(.status)
        await fixture.imap.releaseHeld(.topEnvelopes)
        await fixture.imap.awaitHeld(.status)
        await first.value
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertTrue(model.isLoading, "the rerun is still out")

        await fixture.scriptRefresh(messages: 4, page: [4, 3, 2, 1])
        await fixture.imap.releaseHeld(.status)
        await second.value
        await third.value

        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3, 2, 1], "the rerun lands last")
        XCTAssertEqual(model.window!.totalMessages, 4)
        XCTAssertFalse(model.isLoading)
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "one rerun answers both")
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(tops.count, 2)
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, [4, 3, 2, 1])
    }

    /// A reset doesn't wait (#1820): the Refresh command, pressed while a
    /// background refresh is out, rebuilds the list at once, and the
    /// background pass's page, fetched before the reset, is dropped when it
    /// lands. The background refresh returns with the reset's pass, which
    /// began after it was asked for.
    func testAResetWhileARefreshIsOutRunsAtOnceAndTheOlderPageIsDropped() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        await fixture.imap.holdNext(.topEnvelopes)
        let background = Task { await model.refresh() }
        await fixture.imap.awaitHeld(.topEnvelopes)

        await fixture.scriptRefresh(messages: 2, page: [5, 4])
        let reset = Task { await model.hardReload() }
        try await waitUntilOnMainActor { model.envelopes.map(\.uid) == [5, 4] }
        XCTAssertTrue(model.isLoading, "the background refresh is still out")

        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        await fixture.imap.releaseHeld(.topEnvelopes)
        await reset.value
        await background.value

        XCTAssertEqual(model.envelopes.map(\.uid), [5, 4], "the older page was dropped")
        XCTAssertEqual(model.window!.totalMessages, 2)
        XCTAssertFalse(model.isLoading)
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "the background STATUS and the reset's probe, and no rerun")
    }

    /// A background refresh's STATUS still out when Refresh rebuilds the list
    /// was asked for before the reset's probe, and may count an older folder.
    /// Landing after the reset, it is dropped: it doesn't put its older
    /// count over the one the reset shows.
    func testAStatusAResetOvertookDoesNotOverwriteTheResetsCounts() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 4, page: [4, 3, 2, 1])
        // Answered in the order they answer: the reset's probe first, with
        // UID 4, then the background STATUS held from before it.
        await fixture.imap.scriptStatusResults([
            .success(fixture.status(messages: 4, uidNext: 5)),
            .success(fixture.status(messages: 3, uidNext: 4)),
        ])
        await fixture.imap.holdNext(.status)
        let background = Task { await model.refresh() }
        await fixture.imap.awaitHeld(.status)

        await model.hardReload()
        XCTAssertEqual(model.window!.totalMessages, 4)
        await fixture.imap.releaseHeld(.status)
        await background.value

        XCTAssertEqual(model.window!.totalMessages, 4, "the older count was dropped")
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3, 2, 1])
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "the background STATUS and the probe; the reset answered both")
        XCTAssertFalse(model.isLoading)
    }

    /// The reset's pass runs on the STATUS its probe asked for, so it answers
    /// only the refreshes asked for before that probe. One asked for while the
    /// probe was out (a folder poll after UID 4 arrived) gets a pass of its
    /// own, which asks afresh, so the count it was asked for shows.
    func testARefreshAskedForWhileAResetsProbeIsOutGetsAFreshStatus() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        // Answered in the order they answer: the background refresh's STATUS
        // first, with UID 4, then the probe's, from before UID 4 arrived.
        await fixture.imap.scriptStatusResults([
            .success(fixture.status(messages: 4, uidNext: 5)),
            .success(fixture.status(messages: 3, uidNext: 4)),
        ])
        await fixture.imap.holdNext(.status)
        let reset = Task { await model.hardReload() }
        await fixture.imap.awaitHeld(.status)
        await fixture.imap.holdNext(.topEnvelopes)
        let background = Task { await model.refresh() }
        await fixture.imap.awaitHeld(.topEnvelopes)

        await fixture.scriptRefresh(messages: 4, page: [4, 3, 2, 1])
        await fixture.imap.releaseHeld(.status)
        await reset.value
        XCTAssertEqual(model.window!.totalMessages, 3, "the reset shows what its probe found")
        await fixture.imap.releaseHeld(.topEnvelopes)
        await background.value

        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 3, "the probe, the background refresh, and its own rerun")
        XCTAssertEqual(model.window!.totalMessages, 4)
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3, 2, 1])
        XCTAssertFalse(model.isLoading)
    }

    func testPullToRefreshSurvivesTheCallersCancellation() async throws {
        let model = try await fixture.makeModel(loaded: [1], total: 1)
        await fixture.scriptRefresh(messages: 2, page: [2, 1])

        let pull = Task { await model.refreshFromPull() }
        pull.cancel()
        await pull.value

        XCTAssertNil(model.errorMessage, "a cancelled pull must not paint an error")
        XCTAssertEqual(model.envelopes.map(\.uid), [2, 1])
    }

    /// The negative control for the pull test, and the path a folder poll's
    /// refresh takes: the poller runs it in a task of the list's own, which
    /// `stopWatching()` cancels when the list disappears. A refresh
    /// in flight when its task is cancelled (the list leaves the screen, for
    /// instance under a pushed reader) is dropped without painting
    /// "cancelled" over the list, which the view would keep in `@State` and
    /// show again on return. Fixed in #1816; this test pinned the banner
    /// until then.
    func testAPlainRefreshInACancelledTaskPaintsNoError() async throws {
        let model = try await fixture.makeModel(loaded: [1], total: 1)
        await fixture.scriptRefresh(messages: 2, page: [2, 1])

        let poll = Task { await model.refresh() }
        poll.cancel()
        await poll.value

        XCTAssertNil(model.errorMessage, "a cancelled refresh has nothing to report")
        XCTAssertEqual(model.envelopes.map(\.uid), [1])
    }

    // MARK: - Sort change

    func testSortChangeAsksStatusOnceAndFetchesTheTopPageInTheNewOrder() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.window!.sortCriterion, subjectOrder)
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        let pages = await fixture.pageCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "the probe's STATUS is reused by the refresh")
        XCTAssertEqual(tops, ["Work limit=50 total=3 subject/ascending"])
        XCTAssertTrue(pages.isEmpty, "no bottom window for a folder under 600 messages")
        XCTAssertFalse(model.isLoading)
    }

    func testSortChangeOnALargeFolderReStagesTheBottomWindowInTheNewOrder() async throws {
        let folder = fixture.newestFirst(1_000, through: 1)
        await fixture.scriptRefresh(messages: 1_000, page: Array(folder.prefix(50)))
        await fixture.imap.scriptFolderContents(fixture.rows(folder))
        let model = try await fixture.makeModel()
        await model.loadInitial()
        await fixture.awaitBottomPrefetch(model)
        XCTAssertEqual(fixture.stagedBottomStart(model), 800)

        await model.window!.setSort(subjectOrder)
        await fixture.awaitBottomPrefetch(model)

        let pages = await fixture.pageCalls()
        XCTAssertEqual(pages, [
            "Work offset=800 limit=200 dateReceived/descending",
            "Work offset=800 limit=200 subject/ascending",
        ])
        XCTAssertEqual(fixture.stagedBottomStart(model), 800)
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(tops, [
            "Work limit=50 total=1000 dateReceived/descending",
            "Work limit=50 total=1000 subject/ascending",
        ])
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "one for the first load, one probe for the sort")

        // End (a far jump to the last row) adopts the re-staged rows with no
        // round trip, and they are in the new order: "Subject 1" sorts first.
        model.window!.ensureLoaded(around: 999)
        await fixture.awaitLoadWindow(model)
        let afterEnd = await fixture.pageCalls()
        XCTAssertEqual(afterEnd.count, 2, "no new page is asked for")
        let bottom = Set((800..<1_000).compactMap { model.window!.envelope(at: $0)?.uid })
        XCTAssertEqual(bottom, Set(UInt32(1)...200))
        XCTAssertEqual(model.window!.envelope(at: 800)?.uid, 1)
    }

    // MARK: - Hard reload, online

    /// A phantom only the snapshot holds (the paginated tail, where a search
    /// once leaked foreign UIDs) survives a plain refresh, which writes the
    /// top page alone, but not Refresh (`hardReload`), which drops the
    /// snapshot before rebuilding.
    func testHardReloadPurgesARowOnlyTheSnapshotHolds() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        try await fixture.seedSnapshot(model, uids: [999, 3, 2, 1])
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])

        await model.refresh()
        let afterRefresh = await fixture.snapshotUIDs(model)
        XCTAssertEqual(afterRefresh, [999, 3, 2, 1], "a refresh only upserts the top page")

        await model.hardReload()

        let afterReload = await fixture.snapshotUIDs(model)
        XCTAssertEqual(afterReload, [3, 2, 1])
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1])
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "one each: the reload's probe is reused by its refresh")
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - First load

    func testLoadInitialMakesNoCallsOnceTheListHasRows() async throws {
        let model = try await fixture.makeModel()
        await fixture.scriptRefresh(messages: 2, page: [2, 1])

        await model.loadInitial()
        await model.loadInitial()

        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(tops.count, 1)
        XCTAssertEqual(model.envelopes.map(\.uid), [2, 1])
    }

    /// The once-guard is the row count, not a flag: the list of an empty
    /// folder loads again on a second call. (The view calls it once per model.)
    func testLoadInitialOnAnEmptyFolderLoadsAgain() async throws {
        let model = try await fixture.makeModel()
        await fixture.scriptRefresh(messages: 0, page: [])

        await model.loadInitial()
        await model.loadInitial()

        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2)
    }
}
