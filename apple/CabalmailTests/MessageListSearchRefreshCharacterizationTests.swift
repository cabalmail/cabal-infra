import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 (the CabalmailUI module split,
/// the AppState split, the mail store layer and the focused-window commands).
/// It pins what `MessageListViewModel`'s refresh entry points do while a
/// search or a filter pill is showing, and on the way in and out of one --
/// the search scope's poll, a pill's background refresh, a sort picked
/// mid-search, the search banner's clear button, and the sticky pill a
/// folder opens on -- so the refactor shows any change in behaviour
/// explicitly. The folder-mode half is `MessageListRefreshCharacterizationTests`.
///
/// Protects 8863f0bb (the sticky pill replays on open, after the STATUS),
/// the clear-search rebuild from STATUS and the top page, and #1796's probe
/// on the sort path. A test whose name ends in `Weakness` pins a known
/// shortcoming on purpose so the refactor can flip it deliberately; it is a
/// record, not a spec. The shared set-up lives in
/// `RefreshCharacterizationFixture.swift`.
@MainActor
final class MessageListSearchRefreshCharacterizationTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private let subjectOrder = SortCriterion(field: .subject, direction: .ascending)

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    // MARK: - Background refresh

    /// The VM half of "the poll is suppressed in search scope": with no search
    /// showing there is no folder to STATUS, so neither entry point calls out.
    func testSearchScopeWithNoSearchMakesNoWireCall() async throws {
        let model = try await fixture.makeSearchScopeModel()

        await model.refresh()
        await model.hardReload()

        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        let searches = await fixture.imap.searchCalls
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(tops.isEmpty)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertNil(model.errorMessage, "the fake's trap would have set one had anything been called")
        XCTAssertFalse(model.isLoading)
    }

    /// Pins a known weakness: while a pill is active, a background refresh
    /// re-runs the pill's search and sends no STATUS, so the pill counts and
    /// the sidebar badge stay where they were however the folder changed.
    /// Tracked in #1819.
    func testPillActiveRefreshReRunsTheSearchAndSendsNoStatusWeakness() async throws {
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([8, 6])))
        await fixture.scriptRefresh(messages: 9, page: [9, 8, 7, 6], unseen: 5)
        model.unseen = 2
        await model.selectFilter(.unread)
        XCTAssertTrue(model.isSearchActive)

        await model.refresh()

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the refresh re-ran the pill's search")
        XCTAssertEqual(searches.last?.unread, true)
        XCTAssertEqual(searches.last?.folder, fixture.folderPath)
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        XCTAssertTrue(statuses.isEmpty, "no STATUS while a pill is active")
        XCTAssertTrue(tops.isEmpty)
        XCTAssertEqual(model.unseen, 2, "so the Unread count is stale; the server says 5")
        XCTAssertEqual(model.filterTab, .unread)
        XCTAssertEqual(model.envelopes.map(\.uid), [8, 6])
    }

    // MARK: - Sort change during a search

    /// Pins a known weakness: a sort picked while a search (or a pill) is
    /// showing still probes STATUS, then drops that answer -- the counts are
    /// neither applied nor zeroed -- and re-runs the search, whose rows keep
    /// the server's order rather than the order just picked.
    /// Tracked in #1822.
    func testSortChangeDuringASearchKeepsTheServersOrderWeakness() async throws {
        let model = try await fixture.makeModel()
        let serverOrder = [
            TestFixtures.makeEnvelope(uid: 1, subject: "Charlie"),
            TestFixtures.makeEnvelope(uid: 3, subject: "Alpha"),
            TestFixtures.makeEnvelope(uid: 2, subject: "Bravo"),
        ]
        await fixture.imap.scriptSearch(fixture.searchResult(serverOrder))
        await model.selectFilter(.unread)
        model.unseen = 2
        await fixture.scriptRefresh(messages: 9, page: [9], unseen: 5)

        await model.setSort(subjectOrder)

        XCTAssertEqual(model.sortCriterion, subjectOrder)
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 3, 2], "by subject it would be [3, 2, 1]")
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "the probe still goes out")
        XCTAssertEqual(model.unseen, 2, "and its answer (5 unread) is dropped")
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        let tops = await fixture.topPageCalls()
        let pages = await fixture.pageCalls()
        XCTAssertTrue(tops.isEmpty)
        XCTAssertTrue(pages.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    /// Pins a known weakness on the same path: `setSort` empties the rows
    /// before the re-run, whose depth is `max(rows, one page)`, so a search
    /// paged in to 100 rows comes back as one page of 50. A plain refresh of
    /// the same search re-walks to the depth already loaded
    /// (`SearchPagingTests.testInPlaceRefreshRewalksToLoadedDepth`).
    /// Tracked in #1822.
    func testSortChangeDuringADeepSearchCollapsesItToOnePageWeakness() async throws {
        let model = try await fixture.makeModel()
        let newer = fixture.rows(fixture.newestFirst(100, through: 51))
        let older = fixture.rows(fixture.newestFirst(50, through: 1))
        await fixture.imap.scriptSearchPages([
            fixture.searchResult(newer, cursor: "c1"),
            fixture.searchResult(older),
            // What a re-run from the top would get, page by page.
            fixture.searchResult(newer, cursor: "r1"),
            fixture.searchResult(older),
        ])
        await model.selectFilter(.unread)
        await model.loadMoreSearchResults()
        XCTAssertEqual(model.envelopes.count, 100)
        await fixture.scriptRefresh(messages: 100, page: [100])

        await model.setSort(subjectOrder)

        XCTAssertEqual(model.envelopes.count, 50, "the 100 rows paged in come back as one page")
        XCTAssertEqual(model.searchNextCursor, "r1")
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 3, "the re-run asked for one page, not the two loaded")
        XCTAssertNil(searches.last?.cursor)
        XCTAssertEqual(searches.last?.limit, 50)
    }

    // MARK: - Leaving a search

    func testClearingASearchOnlineRebuildsTheFolderFromStatusAndTheTopPage() async throws {
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([7, 5])))
        await model.selectFilter(.unread)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 1, flagged: 1)

        await model.clearSearch()

        XCTAssertFalse(model.isSearchActive)
        XCTAssertEqual(model.filterTab, .all)
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertEqual(model.totalMessages, 3)
        XCTAssertEqual(model.unseen, 1)
        XCTAssertEqual(model.flagged, 1)
        XCTAssertNil(model.errorMessage)
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
        XCTAssertEqual(tops, ["Work limit=50 total=3 dateReceived/descending"])
    }

    /// Pins a quirk that looks like a defect: clearing a pill's search (the
    /// search banner's clear button calls `clearSearch` directly) puts the
    /// list back on All but leaves the folder's sticky pill at the Unread
    /// that `selectFilter` saved, so the folder opens on Unread again next
    /// time. Choosing All on the pill itself saves All.
    /// Tracked in #1826.
    func testClearingAPillSearchLeavesTheStickyPillSetWeakness() async throws {
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([7, 5])))
        await model.selectFilter(.unread)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 1)

        await model.clearSearch()

        XCTAssertEqual(model.filterTab, .all)
        XCTAssertEqual(model.preferences.mailFolderFilter(for: fixture.folderPath), .unread)
        let reopened = fixture.reopen(model)
        await reopened.loadInitial()
        XCTAssertEqual(reopened.filterTab, .unread, "the folder opens on the pill the banner cleared")
        XCTAssertTrue(reopened.isSearchActive)
        XCTAssertEqual(reopened.envelopes.map(\.uid), [7, 5])

        await reopened.selectFilter(.all)

        XCTAssertEqual(reopened.preferences.mailFolderFilter(for: fixture.folderPath), .all)
    }

    // MARK: - Opening on a sticky pill

    func testLoadInitialReplaysTheStickyPillAfterTheStatus() async throws {
        let model = try await fixture.makeModel()
        model.preferences.setMailFolderFilter(.unread, for: fixture.folderPath)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([3, 1])))
        await fixture.imap.holdNext(.status)

        let load = Task { await model.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        XCTAssertEqual(model.filterTab, .unread, "the pill shows from the first paint")
        let early = await fixture.imap.searchCalls
        XCTAssertTrue(early.isEmpty, "the pill's search waits for the STATUS")
        await fixture.imap.releaseHeld(.status)
        await load.value

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.unread, true)
        XCTAssertEqual(searches.first?.flagged, false)
        XCTAssertEqual(searches.first?.folder, fixture.folderPath)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 1])
        XCTAssertEqual(model.unseen, 2, "the pill counts come from the STATUS")
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(tops.count, 1, "the folder's top page loads before the pill's search replaces it")
    }
}
