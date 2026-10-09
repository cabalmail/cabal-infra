import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Message lists on the folder pollers (2.2 D): lists showing one folder
/// share its change stream, a change asks STATUS once and each list
/// refreshes from it, a list that closes leaves the rest refreshing, a list
/// that comes back while its stop is still out ends watched (#1816), and
/// sign-out stops them all. The single-list watcher behaviour is the
/// watcher characterization suites'; they build a store per list, so these
/// open the folder again on one store and one client, as a second window
/// does (`FolderPollListWorld`). What a poll's answer does to a list is
/// `MessageListFolderPollRefreshTests`'.
@MainActor
final class MessageListFolderPollTests: XCTestCase {
    private var world: FolderPollListWorld!

    override func setUp() async throws {
        world = FolderPollListWorld()
        await world.setUp()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    // MARK: - The brief's three

    func testTwoListsOnOneFolderOpenOneStreamAndAskOneStatusPerEvent() async throws {
        let (first, second) = try await world.twoListsOnWork()
        await first.startWatching()
        await second.startWatching()
        XCTAssertEqual(try world.poller(first).subscriberCount, 2)
        try await world.awaitStreams()

        try await world.emitHoldingStatus()
        XCTAssertTrue(first.isLoading, "each list reads as loading while the one STATUS is out")
        XCTAssertTrue(second.isLoading)
        XCTAssertEqual(first.envelopes.map(\.uid), [5, 4, 3, 2, 1], "nothing moves before the server answers")
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !first.isLoading && !second.isLoading }

        XCTAssertEqual(first.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(second.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        let opened = await world.imap.idleFolders
        XCTAssertEqual(opened, ["Work"], "one stream for the folder")
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"], "one STATUS for both lists")
        let pages = await world.fixture.topPageCalls()
        XCTAssertEqual(pages.count, 2, "each list folds in its own top page")
        XCTAssertNil(first.errorMessage)
        XCTAssertNil(second.errorMessage)
    }

    func testClosingOneListLeavesTheOtherRefreshing() async throws {
        let (closed, open) = try await world.twoListsOnWork()
        await closed.startWatching()
        await open.startWatching()
        try await world.awaitStreams()

        await closed.stopWatching()
        XCTAssertEqual(try world.poller(open).subscriberCount, 1)
        try await world.emitHoldingStatus()
        XCTAssertFalse(closed.isLoading)
        XCTAssertTrue(open.isLoading)
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !open.isLoading }

        XCTAssertEqual(open.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(closed.envelopes.map(\.uid), [5, 4, 3, 2, 1], "the closed list takes no part")
        XCTAssertEqual(closed.window!.totalMessages, 5)
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])
        let pages = await world.fixture.topPageCalls()
        XCTAssertEqual(pages.count, 1)
        let terminations = await world.imap.idleTerminations
        XCTAssertEqual(terminations, 0, "the stream stays open while a list shows the folder")

        await open.stopWatching()
        try await world.awaitTerminations(1)
        XCTAssertNil(world.pollers.poller(for: "Work", through: open.client), "and stops with the last")
    }

    /// The view stops a list on an unstructured task, so a re-appear's start
    /// can land while the stop of the folder's last list still waits on its
    /// watcher. The stop took the poller out before it waited, so the start
    /// makes a fresh one, and the old stop, finishing after, leaves that one
    /// in place: a later stop ends the fresh stream.
    func testAReappearWithinTheLastListsStopStillEndsWatched() async throws {
        let (returning, gone) = try await world.twoListsOnWork()
        await returning.startWatching()
        await gone.startWatching()
        try await world.awaitStreams()
        await gone.stopWatching()

        let stopping = Task { await returning.stopWatching() }
        await Task.yield()
        await returning.startWatching()
        await stopping.value

        XCTAssertEqual(try world.poller(returning).subscriberCount, 1, "watched once the stop is done")
        try await world.awaitStreams(2)
        try await world.awaitTerminations(1)
        try await world.emitHoldingStatus()
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { returning.envelopes.count == 6 && !returning.isLoading }
        XCTAssertEqual(gone.envelopes.map(\.uid), [5, 4, 3, 2, 1], "the list that left hears nothing")
        let statuses = await world.fixture.statusCalls()
        XCTAssertEqual(statuses, ["Work flagged=true"])

        await returning.stopWatching()
        try await world.awaitTerminations(2)
    }

    /// The same while another list keeps the folder: the re-appear rejoins
    /// its poller, on the stream already open.
    func testAReappearWithinAStopWhileAnotherListKeepsTheFolderRejoinsIt() async throws {
        let (returning, staying) = try await world.twoListsOnWork()
        await returning.startWatching()
        await staying.startWatching()
        try await world.awaitStreams()

        let stopping = Task { await returning.stopWatching() }
        await Task.yield()
        await returning.startWatching()
        await stopping.value

        XCTAssertEqual(try world.poller(returning).subscriberCount, 2)
        try await world.emitHoldingStatus()
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !returning.isLoading && !staying.isLoading }
        XCTAssertEqual(returning.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(staying.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        let opened = await world.imap.idleFolders
        XCTAssertEqual(opened, ["Work"])
    }

    // MARK: - Leaving and sign-out

    func testAListClosedWhileTheStatusIsOutDropsItsSpinnerAndTakesNothing() async throws {
        let (closed, open) = try await world.twoListsOnWork()
        await closed.startWatching()
        await open.startWatching()
        try await world.awaitStreams()
        try await world.emitHoldingStatus()

        await closed.stopWatching()
        XCTAssertFalse(closed.isLoading, "its hold went with it")
        XCTAssertTrue(open.isLoading)
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { !open.isLoading }

        XCTAssertEqual(open.envelopes.map(\.uid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(closed.envelopes.map(\.uid), [5, 4, 3, 2, 1])
        XCTAssertNil(closed.errorMessage)
        let pages = await world.fixture.topPageCalls()
        XCTAssertEqual(pages.count, 1)
    }

    /// Sign-out marks the client ended, then forgets the account: every
    /// poller stops at once, every hold is given back, the stream ends, and
    /// a STATUS answered after it reaches no list (#1886). A list of the
    /// ended session joins nothing afterwards, and its view's late stop is a
    /// no-op.
    func testSignOutStopsEveryPollerAndAStatusAnsweredLateReachesNoList() async throws {
        let (first, second) = try await world.twoListsOnWork()
        await first.startWatching()
        await second.startWatching()
        let poller = try world.poller(first)
        try await world.awaitStreams()
        await world.imap.answerStatusAfterCancellation()
        try await world.emitHoldingStatus()

        world.fixture.appState.sessionManager.teardownGate.markEnded(first.client)
        world.fixture.mailStore.forgetAccount()
        XCTAssertNil(world.pollers.poller(for: "Work", through: first.client))
        XCTAssertFalse(first.isLoading || second.isLoading, "every hold is given back at once")
        await world.imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        let pages = await world.fixture.topPageCalls()
        XCTAssertTrue(pages.isEmpty, "the late answer refreshed no list")
        XCTAssertEqual(first.envelopes.map(\.uid), [5, 4, 3, 2, 1])
        XCTAssertNil(first.errorMessage)
        try await world.awaitTerminations(1)
        await first.startWatching()
        XCTAssertNil(world.pollers.poller(for: "Work", through: first.client), "an ended session joins nothing")
        await first.stopWatching()
    }
}
