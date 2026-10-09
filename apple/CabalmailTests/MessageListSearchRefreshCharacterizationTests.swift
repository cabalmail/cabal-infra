import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 (the CabalmailUI module split,
/// the AppState split, the mail store layer and the focused-window commands).
/// It pins what `MessageListViewModel`'s refresh entry points do while a
/// search or a filter pill is showing, and on the way in and out of one --
/// the search scope's refresh, a pill's background refresh, a sort picked
/// mid-search, the search banner's clear button, and the sticky pill a
/// folder opens on -- so the refactor shows any change in behaviour
/// explicitly. The folder-mode half is `MessageListRefreshCharacterizationTests`.
///
/// Protects 8863f0bb (the sticky pill replays on open, after the STATUS),
/// the clear-search rebuild from STATUS and the top page, a pill's refresh
/// taking its counts from STATUS (#1819), and a sort pick leaving a search's
/// rows alone (#1822). A test whose name ends in `Weakness` pins a known
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

    /// The search surface joins no folder poller, and with no search showing
    /// there is no folder to STATUS, so neither entry point calls out.
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

    /// While a pill is active, a background refresh asks for STATUS before
    /// it re-runs the pill's search, so the pill counts and the sidebar badge
    /// follow the folder. Fixed in #1819; this test pinned the missing STATUS
    /// until then.
    func testPillActiveRefreshTakesTheCountsFromStatusAndReRunsTheSearch() async throws {
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
        XCTAssertEqual(statuses, ["Work flagged=true"], "STATUS for the counts")
        XCTAssertTrue(tops.isEmpty, "but no top page under the pill")
        XCTAssertEqual(model.unseen, 5, "the Unread count follows the server")
        XCTAssertEqual(model.filterTab, .unread)
        XCTAssertEqual(model.envelopes.map(\.uid), [8, 6])
    }

    // MARK: - Sort change during a search

    /// The menu is off during a search (`sortApplies`), so this is the model
    /// left to itself: a sort picked while a search (or a pill) is showing
    /// is recorded for the folder view, and the probe's counts are applied.
    /// The results keep the server's order, and there is no re-run. Fixed in
    /// #1822; this test pinned the probe thrown away until then.
    func testSortChangeDuringASearchKeepsTheResultsAndTakesTheCounts() async throws {
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

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.window!.sortCriterion, subjectOrder, "kept for the folder view")
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 3, 2], "the server's order")
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "the probe")
        XCTAssertEqual(model.unseen, 5, "whose counts are applied")
        XCTAssertNil(model.errorMessage)
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1, "and no re-run")
        let tops = await fixture.topPageCalls()
        let pages = await fixture.pageCalls()
        XCTAssertTrue(tops.isEmpty)
        XCTAssertTrue(pages.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    /// On the same path, a search paged in to 100 rows keeps all 100 when a
    /// sort is picked, rather than coming back as one page of 50. Fixed in
    /// #1822; this test pinned the cut until then.
    func testSortChangeDuringADeepSearchKeepsEveryRowPagedIn() async throws {
        let model = try await fixture.makeModel()
        let newer = fixture.rows(fixture.newestFirst(100, through: 51))
        let older = fixture.rows(fixture.newestFirst(50, through: 1))
        await fixture.imap.scriptSearchPages([
            fixture.searchResult(newer, cursor: "c1"),
            fixture.searchResult(older),
        ])
        await model.selectFilter(.unread)
        await model.search.loadMore()
        XCTAssertEqual(model.envelopes.count, 100)
        await fixture.scriptRefresh(messages: 100, page: [100], unseen: 100)

        await model.window!.setSort(subjectOrder)

        XCTAssertEqual(model.envelopes.count, 100, "every row paged in stays")
        XCTAssertEqual(model.envelopes.map(\.uid), fixture.newestFirst(100, through: 1), "in the server's order")
        XCTAssertEqual(model.window!.sortCriterion, subjectOrder)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.search.nextCursor)
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "the probe")
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the pill's page and the one scrolled in; no re-run")
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
        XCTAssertEqual(model.window!.totalMessages, 3)
        XCTAssertEqual(model.unseen, 1)
        XCTAssertEqual(model.flagged, 1)
        XCTAssertNil(model.errorMessage)
        let statuses = await fixture.statusCalls()
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
        XCTAssertEqual(tops, ["Work limit=50 total=3 dateReceived/descending"])
    }

    /// The pill a folder reopens on follows the pill on screen (#1826): a pill search ended by a route
    /// other than the pill -- the search banner's clear button calls `clearSearch` directly, and a text
    /// search takes a pill's place through `runSearch` -- records All for the folder, as choosing All on
    /// the pill does. A clear with no pill showing leaves the folder's choice alone.
    func testEndingAPillSearchAnotherWayRecordsAllForTheFolder() async throws {
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([7, 5])))
        await model.selectFilter(.unread)
        XCTAssertEqual(model.preferences.mailFolderFilter(for: fixture.folderPath), .unread, "the tap records it")
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 1)

        await model.clearSearch()

        XCTAssertEqual(model.filterTab, .all)
        XCTAssertEqual(model.preferences.mailFolderFilter(for: fixture.folderPath), .all)
        let reopened = fixture.reopen(model)
        await reopened.loadInitial()
        XCTAssertEqual(reopened.filterTab, .all, "the folder opens on the pill the clear left on screen")
        XCTAssertFalse(reopened.isSearchActive)
        XCTAssertEqual(reopened.envelopes.map(\.uid), [3, 2, 1])
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1, "only the pill's own search ran")

        await model.selectFilter(.flagged)
        model.searchQuery = "invoice"
        await model.runSearch()
        XCTAssertEqual(model.filterTab, .all)
        XCTAssertEqual(
            model.preferences.mailFolderFilter(for: fixture.folderPath), .all, "a text search in the pill's place"
        )

        model.preferences.setMailFolderFilter(.flagged, for: fixture.folderPath)
        await model.clearSearch()
        XCTAssertEqual(
            model.preferences.mailFolderFilter(for: fixture.folderPath), .flagged, "no pill was on screen to end"
        )
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
