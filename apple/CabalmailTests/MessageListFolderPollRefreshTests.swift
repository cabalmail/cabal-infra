import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a folder poll's answer does to the message lists on it (2.2 D): the
/// ask is numbered before the STATUS goes out, so it answers no refresh
/// asked after it; a failed STATUS shows on every folder list, unless the
/// list's own refresh has answered for it since, and no list asks again; one
/// STATUS feeds a pill's search and a folder view's rows alike; and the
/// folder's tick refreshes every list from one STATUS. The lists share one
/// store and one client (`FolderPollListWorld`).
@MainActor
final class MessageListFolderPollRefreshTests: XCTestCase {
    private var world: FolderPollListWorld!

    override func setUp() async throws {
        world = FolderPollListWorld()
        await world.setUp()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// The pull's STATUS answers first and sees the new message; the poll's,
    /// held from before the pull, answers after with the folder as it was.
    func testARefreshAskedWhileThePollsStatusIsOutIsNotUndoneByIt() async throws {
        let list = try await world.oneListOnWork()
        await world.imap.scriptStatusResults([
            .success(world.fixture.status(messages: 6, uidNext: 7)),
            .success(world.fixture.status(messages: 5, uidNext: 6)),
        ])
        await list.startWatching()
        let poller = try world.poller(list)
        try await world.awaitStreams()
        try await world.emitHoldingStatus()

        await list.refreshFromPull()
        XCTAssertEqual(list.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1], "the pull's STATUS saw the new message")
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        XCTAssertEqual(list.window!.totalMessages, 6, "the older STATUS answered no refresh asked after it")
        let pages = await world.fixture.topPageCalls()
        XCTAssertEqual(pages.count, 1)
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses.count, 2)
    }

    func testAFailedPollShowsTheErrorOnEveryFolderListAndNoListAsksAgain() async throws {
        let offline = CabalmailError.network("offline")
        await world.imap.scriptStatusResults([.failure(offline)])
        let (first, second) = try await world.twoListsOnWork()
        await first.startWatching()
        await second.startWatching()
        let poller = try world.poller(first)
        try await world.awaitStreams()

        await world.emit()
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        XCTAssertEqual(first.errorMessage, offline.localizedDescription)
        XCTAssertEqual(second.errorMessage, offline.localizedDescription)
        XCTAssertFalse(first.isLoading || second.isLoading)
        XCTAssertEqual(first.envelopes.map(\.uid), [5, 4, 3, 2, 1], "the rows stay")
        XCTAssertEqual(second.window!.totalMessages, 5)
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "no list falls back to a STATUS of its own")
        let pages = await world.fixture.topPageCalls()
        XCTAssertTrue(pages.isEmpty)
    }

    func testAFailedPollAfterTheListsOwnRefreshShowsNoError() async throws {
        let list = try await world.oneListOnWork()
        await world.imap.scriptStatusResults([
            .success(world.fixture.status(messages: 6, uidNext: 7)),
            .failure(CabalmailError.network("offline")),
        ])
        await list.startWatching()
        let poller = try world.poller(list)
        try await world.awaitStreams()
        try await world.emitHoldingStatus()

        await list.refreshFromPull()
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        XCTAssertNil(list.errorMessage, "the list's own pass, asked later, answered for the poll")
        XCTAssertEqual(list.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertFalse(list.isLoading)
    }

    func testOnePollFeedsAPillListsSearchAndAFolderListsRows() async throws {
        let (pill, plain) = try await world.twoListsOnWork()
        let fixture = world.fixture
        await world.imap.scriptSearch(fixture.searchResult(fixture.rows([4])))
        await fixture.scriptRefresh(messages: 6, page: fixture.newestFirst(6, through: 1), unseen: 1)
        await pill.applyFilter(.unread)
        XCTAssertTrue(pill.isSearchActive)
        await pill.startWatching()
        await plain.startWatching()
        let poller = try world.poller(pill)
        try await world.awaitStreams()

        await world.emit()
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        let searches = await world.imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the pill's own search, then the poll's re-run")
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "one STATUS for both")
        let pages = await fixture.topPageCalls()
        XCTAssertEqual(pages.count, 1, "the folder view's top page; the pill re-ran its search instead")
        XCTAssertEqual(pill.envelopes.map(\.uid), [4])
        XCTAssertEqual(pill.filterTab, .unread)
        XCTAssertEqual(pill.unseen, 1, "the folder's counts come from the one STATUS")
        XCTAssertEqual(plain.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertFalse(pill.isLoading || plain.isLoading)
    }

    /// As a pill's own refresh takes a STATUS that fails: the counts stay,
    /// the search runs again, and no error shows.
    func testAFailedPollRerunsAPillsSearchWithoutAnError() async throws {
        let pill = try await world.oneListOnWork()
        let fixture = world.fixture
        await world.imap.scriptSearch(fixture.searchResult(fixture.rows([4])))
        await world.imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        await pill.applyFilter(.unread)
        await pill.startWatching()
        let poller = try world.poller(pill)
        try await world.awaitStreams()

        await world.emit()
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        let searches = await world.imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the pill's own search, then the re-run")
        XCTAssertNil(pill.errorMessage)
        XCTAssertEqual(pill.envelopes.map(\.uid), [4])
        let statuses = await fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
        XCTAssertFalse(pill.isLoading)
    }

    func testTheTickRefreshesBothListsFromOneStatus() async throws {
        let (first, second) = try await world.twoListsOnWork()
        await first.startWatching()
        await second.startWatching()
        try await world.clock.awaitSleepers(1)
        let none = await world.fixture.statusCalls()
        XCTAssertEqual(none, [], "no STATUS as the lists join: they have just loaded")

        let imap = world.imap
        await imap.holdNext(.status)
        world.clock.fireTicks()
        try await awaitArrival { await imap.statusCalls.count == 1 }
        await imap.awaitHeld(.status)
        XCTAssertTrue(first.isLoading && second.isLoading)
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !first.isLoading && !second.isLoading }
        XCTAssertEqual(first.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(second.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
    }
}
