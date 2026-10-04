import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 (the CabalmailUI module split,
/// AppState split into per-window navigation and a per-account session, the
/// mail store layer, and focused-window commands replacing the integer tick
/// counters). It pins what `MessageListViewModel`'s folder refresh entry
/// points do today -- the calls the 60-second poll, the IDLE watcher,
/// pull-to-refresh, the Refresh command, the sort menu and the first load
/// make -- so the refactor shows any change in behaviour explicitly. What
/// they do while a search or a pill is showing is pinned in
/// `MessageListSearchRefreshCharacterizationTests`.
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
        XCTAssertEqual(model.totalMessages, 3)
        XCTAssertEqual(model.unseen, 1)
        let tops = await fixture.topPageCalls()
        XCTAssertTrue(tops.isEmpty, "no top page is asked for once STATUS fails")
    }

    // MARK: - Concurrency and cancellation

    /// Pins a known weakness: `refresh()` is not single-flight. A second
    /// refresh started while the first is parked goes to the wire too, and
    /// its `defer` lowers `isLoading` while the first is still in flight,
    /// which re-opens `ensureLoaded`'s gate mid-refresh. Nothing merges the
    /// two answers either: for a window that fits one top page, the page that
    /// lands last is authoritative. So a stale page, asked for before new
    /// mail arrived, that lands after a newer refresh prunes that mail from
    /// the list, the snapshot and the body cache until the next refresh.
    /// Tracked in #1820.
    func testOverlappingRefreshesBothHitTheWireAndAStalePageLandingLastWinsWeakness() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        await fixture.imap.holdNext(.topEnvelopes)
        let stale = Task { await model.refresh() }
        await fixture.imap.awaitHeld(.topEnvelopes)
        XCTAssertTrue(model.isLoading)

        // UID 4 arrives, and a second refresh sees it.
        await fixture.scriptRefresh(messages: 4, page: [4, 3, 2, 1])
        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3, 2, 1])
        XCTAssertFalse(model.isLoading, "lowered by the second refresh while the first is still parked")
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2, "nothing made the second refresh wait for or join the first")
        try await fixture.storeBody(model, uid: 4)

        // The first refresh's page, from before UID 4 arrived, lands last.
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])
        await fixture.imap.releaseHeld(.topEnvelopes)
        await stale.value

        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1], "the last page to land wins, so UID 4 is pruned")
        XCTAssertEqual(model.totalMessages, 4, "while the count stays the newer refresh's")
        let cached = await fixture.snapshotUIDs(model)
        XCTAssertEqual(cached, [3, 2, 1])
        let prunedBody = await fixture.cachedBody(model, uid: 4)
        XCTAssertNil(prunedBody)
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(tops.count, 2)
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

    /// The negative control for the pull test, and the path the view's
    /// 60-second poll takes (it calls `refresh()` directly from its `.task`).
    /// The IDLE watcher's refresh runs inside `watcherTask`, which
    /// `stopWatching()` cancels when the list disappears, so it takes the
    /// same path. Pins current behaviour, which looks like a defect: a
    /// refresh in flight when its task is cancelled (the list leaves the
    /// screen, for instance under a pushed reader) paints "cancelled" over
    /// the list, which the view keeps in `@State` and shows again on return
    /// -- the #736 / #403 class that `loadInitial` and `refreshFromPull` were
    /// moved off.
    /// Tracked in #1816.
    func testAPlainRefreshInACancelledTaskShowsCancelledWeakness() async throws {
        let model = try await fixture.makeModel(loaded: [1], total: 1)
        await fixture.scriptRefresh(messages: 2, page: [2, 1])

        let poll = Task { await model.refresh() }
        poll.cancel()
        await poll.value

        let shown = try XCTUnwrap(model.errorMessage, "a cancelled refresh paints an error")
        XCTAssertTrue(shown.contains("cancelled"), shown)
        XCTAssertEqual(model.envelopes.map(\.uid), [1])
    }

    // MARK: - Sort change

    func testSortChangeAsksStatusOnceAndFetchesTheTopPageInTheNewOrder() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])

        await model.setSort(subjectOrder)

        XCTAssertEqual(model.sortCriterion, subjectOrder)
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

        await model.setSort(subjectOrder)
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
        model.ensureLoaded(around: 999)
        await fixture.awaitLoadWindow(model)
        let afterEnd = await fixture.pageCalls()
        XCTAssertEqual(afterEnd.count, 2, "no new page is asked for")
        let bottom = Set((800..<1_000).compactMap { model.envelope(at: $0)?.uid })
        XCTAssertEqual(bottom, Set(UInt32(1)...200))
        XCTAssertEqual(model.envelope(at: 800)?.uid, 1)
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
