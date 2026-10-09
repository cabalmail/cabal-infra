import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The refresh-routing fixes (#1816, #1819, #1821, #1822, #1814) beyond the
/// characterization tests they flipped: the watcher coming back with the
/// list, a pill's counts on Refresh, a search refresh that is cancelled, the
/// sort menu during a search, and the user-facing error copy on the list's
/// own write paths. A stopped watcher starting again on the same model is
/// `MessageListWatcherTeardownCharacterizationTests`' to pin.
@MainActor
final class MessageListRefreshRoutingTests: XCTestCase {
    private var harness: ListWatcherHarness!

    override func setUp() async throws {
        harness = ListWatcherHarness()
        await harness.imap.scriptIdle()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
    }

    // MARK: - #1816: the watcher comes back with the list

    /// The view stops the watcher on an unstructured task, so a start can
    /// land while the stop is still waiting for the old watcher. That start
    /// gets a fresh watcher rather than finding the old one and doing
    /// nothing, which would leave the list unwatched once the stop finished.
    func testAStartDuringAStopStillLeavesTheListWatched() async throws {
        let imap = harness.imap
        await harness.scriptNewMessage()
        let model = try harness.makeModel()
        await model.startWatching()
        try await harness.awaitStreams(1)

        let stopping = Task { await model.stopWatching() }
        await Task.yield()
        await model.startWatching()
        await stopping.value

        try await harness.awaitStreams(2)
        try await harness.emitAndCatchRefresh(.exists(6))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { model.envelopes.count == 6 && !model.isLoading }
    }

    /// The view half (#1816): the list's `.task` runs on every appearance,
    /// and with a model already built it starts the watcher again, since
    /// `.onDisappear` stopped it, then refreshes for whatever arrived while
    /// it was away, which the new watcher takes as already there. A scan,
    /// because no test here renders the list; the model behaviour it relies
    /// on is the test above and the teardown suite's restart test.
    func testTheListStartsItsWatcherAgainWhenItReappears() throws {
        let source = try String(
            contentsOf: Self.apple.appendingPathComponent("CabalmailUI/Mail/MessageList/MessageListView.swift"),
            encoding: .utf8
        )
        let reappear = try XCTUnwrap(source.range(of: "} else if !isSearchScope {"), "the re-appear branch")
        let tail = String(source[reappear.upperBound...].prefix(600))
        let start = try XCTUnwrap(tail.range(of: "await model?.startWatching()"), "starts the watcher again")
        XCTAssertTrue(tail[start.upperBound...].contains("await model?.refresh()"), "then refreshes")
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    // MARK: - #1819: Refresh with a pill on

    /// The toolbar or menu Refresh with a pill on zeroes the counts, asks
    /// STATUS once before it drops anything, and re-runs the pill's search:
    /// the counts come back from that one STATUS rather than staying at 0.
    func testARefreshWithAPillOnTakesTheCountsFromItsOneStatus() async throws {
        let fixture = RefreshCharacterizationFixture()
        defer { fixture.removeScratch() }
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([8, 6])))
        await fixture.scriptRefresh(messages: 9, page: [9, 8, 7, 6], unseen: 5, flagged: 1)
        await model.selectFilter(.unread)

        await model.hardReload()

        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "the reload's own STATUS, used once")
        XCTAssertEqual(model.unseen, 5)
        XCTAssertEqual(model.flagged, 1)
        XCTAssertEqual(model.window!.totalMessages, 9)
        XCTAssertEqual(model.envelopes.map(\.uid), [8, 6])
        XCTAssertEqual(model.filterTab, .unread)
    }

    // MARK: - A search refresh that is cancelled keeps its cursor

    /// A pill's refresh cancelled mid-search (the list left the screen) paints
    /// no error (#1816) and leaves the rows it had, so it leaves their cursor
    /// too: the next scroll still pages in the rest of the search.
    func testACancelledSearchRefreshKeepsTheCursorForTheRowsItLeaves() async throws {
        let fixture = RefreshCharacterizationFixture()
        defer { fixture.removeScratch() }
        let model = try await fixture.makeModel()
        let firstPage = fixture.rows(fixture.newestFirst(100, through: UInt32(101 - Self.searchPage)))
        // One page and no more: the refresh's search finds nothing scripted
        // and fails, as a cancelled request does.
        await fixture.imap.scriptSearchPages([fixture.searchResult(firstPage, cursor: "c1")])
        await model.selectFilter(.unread)
        XCTAssertEqual(model.search.nextCursor, "c1")
        await fixture.scriptRefresh(messages: 100, page: [100], unseen: 60)
        await fixture.imap.holdNextSearch()

        let poll = Task { await model.refresh() }
        await fixture.imap.awaitHeldSearch()
        poll.cancel()
        await fixture.imap.releaseHeldSearch()
        await poll.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.envelopes.count, Self.searchPage)
        XCTAssertEqual(model.search.nextCursor, "c1", "the rows still page on")
        XCTAssertFalse(model.isLoading)
    }

    private static let searchPage = MailSearchSession.pageSize

    // MARK: - #1822: the sort menu during a search

    /// Search results come from the server newest first and can't be asked
    /// for in another order, so the sort menu is off while one is showing,
    /// a pill's included, and on the search screen.
    func testTheSortMenuAppliesOnlyToTheFolderView() async throws {
        let fixture = RefreshCharacterizationFixture()
        defer { fixture.removeScratch() }
        let model = try await fixture.makeModel()
        XCTAssertTrue(model.sortApplies)

        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([7, 5])))
        await model.selectFilter(.unread)
        XCTAssertFalse(model.sortApplies, "not under a pill")

        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 1)
        await model.clearSearch()
        XCTAssertTrue(model.sortApplies, "back in the folder view")

        let search = try await fixture.makeSearchScopeModel()
        XCTAssertFalse(search.sortApplies, "nor on the search screen")
    }

    /// A sort picked in the folder view whose probe is still out when a pill
    /// is chosen: the pill's results stay as they came, and the sort is kept
    /// for the folder view, rather than the rows being wiped and the pill's
    /// search run a second time.
    func testASortWhoseProbeAPillOvertookLeavesThePillsResults() async throws {
        let fixture = RefreshCharacterizationFixture()
        defer { fixture.removeScratch() }
        let subjectOrder = SortCriterion(field: .subject, direction: .ascending)
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([3, 1])))
        await fixture.imap.holdNext(.status)

        let sort = Task { await model.window!.setSort(subjectOrder) }
        await fixture.imap.awaitHeld(.status)
        await model.selectFilter(.unread)
        await fixture.imap.releaseHeld(.status)
        await sort.value

        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.map(\.uid), [3, 1])
        XCTAssertEqual(model.window!.sortCriterion, subjectOrder)
        XCTAssertEqual(model.unseen, 2, "the probe's counts")
        let searches = await fixture.imap.searchCalls
        let tops = await fixture.topPageCalls()
        XCTAssertEqual(searches.count, 1, "the pill's search ran once")
        XCTAssertTrue(tops.isEmpty, "and the folder's top page wasn't fetched under it")
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - #1814: the list's failed writes show user-facing copy

    func testAFailedFlagShowsTheUserFacingError() async throws {
        let imap = FakeImapClient()
        let offline = CabalmailError.network("offline")
        await imap.scriptFlagResults([.failure(offline)])
        let row = TestFixtures.makeEnvelope(uid: 1)
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [row])

        await model.setFlag(.seen, add: true, envelope: row)

        XCTAssertEqual(model.errorMessage, offline.localizedDescription)
    }

    func testAFailedMoveShowsTheUserFacingError() async throws {
        let imap = FakeImapClient()
        let offline = CabalmailError.network("offline")
        await imap.scriptMoveResults([.failure(offline)])
        let row = TestFixtures.makeEnvelope(uid: 1)
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [row])

        await model.moveTo(row, destination: "Archive")

        XCTAssertEqual(model.errorMessage, offline.localizedDescription)
        XCTAssertEqual(model.envelopes.map(\.uid), [1], "and the row is back")
    }
}
