import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FolderPollers` against recording lists and a manual clock (2.2 D): one
/// poller per folder, lists counted once and held weakly, the tick and the
/// burst coalesce on the injected clock, each list's own ask taken before
/// the one STATUS and every ticket back exactly once, one poll at a time,
/// and nothing polled for an ended session or after sign-out. What a
/// message list does with a poll is `MessageListFolderPollTests`'.
@MainActor
final class FolderPollersTests: XCTestCase {
    private static let work = "Work"
    private static let status = FolderStatus(messages: 6, unseen: 0, flagged: 0, uidValidity: 7, uidNext: 7)

    private var imap: FakeImapClient!
    private var gate: SessionTeardownGate!
    private var clock: ManualPollClock!
    private var pollers: FolderPollers!
    private var client: CabalmailClient!
    private var clients: [CabalmailClient] = []

    override func setUp() async throws {
        imap = FakeImapClient()
        await imap.scriptIdle()
        await imap.scriptInitialLoad(status: Self.status, topEnvelopes: [])
        gate = SessionTeardownGate()
        clock = ManualPollClock()
        pollers = FolderPollers(teardownGate: gate)
        clock.install(on: pollers)
        client = try makeClient()
    }

    override func tearDown() async throws {
        pollers.stopAll()
        for made in clients {
            let root = await made.bodyCache.directory.deletingLastPathComponent()
            if root.lastPathComponent.hasPrefix("cabalmail-tests-") { try? FileManager.default.removeItem(at: root) }
        }
        clients = []
    }

    func testAListSubscribedTwiceIsCountedOnceAndOneLeaveStopsItsPoller() async throws {
        let list = RecordingPollSubscriber()
        pollers.subscribe(list, to: Self.work, through: client)
        pollers.subscribe(list, to: Self.work, through: client)
        XCTAssertEqual(try workPoller().subscriberCount, 1)
        try await awaitStreams(1)
        XCTAssertNil(pollers.unsubscribe(RecordingPollSubscriber(), from: Self.work, through: client))
        XCTAssertEqual(try workPoller().subscriberCount, 1, "a list not on it takes nothing off")

        let stopped = pollers.unsubscribe(list, from: Self.work, through: client)
        XCTAssertNotNil(stopped, "one leave undoes both subscribes")
        XCTAssertNil(pollers.poller(for: Self.work, through: client), "out of the map before any wait")
        await stopped?.awaitWatcherStop()
        try await awaitTerminations(1)
        let opened = await imap.idleFolders
        XCTAssertEqual(opened, [Self.work], "one stream")
    }

    func testTheTickSleepsFirstThenAsksOneFlaggedStatusForEveryListWithItsOwnAsk() async throws {
        let first = RecordingPollSubscriber(firstAsk: 10)
        let second = RecordingPollSubscriber(firstAsk: 20)
        pollers.subscribe(first, to: Self.work, through: client)
        pollers.subscribe(second, to: Self.work, through: client)
        let poller = try workPoller()
        try await clock.awaitSleepers(1)
        XCTAssertEqual(clock.sleeps, [.seconds(60)], "one tick for the folder, a minute away")
        XCTAssertEqual(poller.pollsRequested, 0, "it sleeps first: no poll as the lists join")

        clock.fireTicks()
        try await waitUntilOnMainActor { first.released.count == 1 && second.released.count == 1 }
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls, [.init(path: Self.work, flagged: true)], "one flagged STATUS for both")
        XCTAssertEqual(first.handed.map(\.ask), [10], "each list is handed its own ask")
        XCTAssertEqual(second.handed.map(\.ask), [20])
        XCTAssertEqual(first.handed.map(\.status), [Self.status])
        XCTAssertEqual(first.handed.first?.askedAt, second.handed.first?.askedAt, "asked once")
        XCTAssertEqual(first.startedOver, [false], "a poll never supersedes a pass")
        XCTAssertEqual(first.released, first.tickets, "and the ticket comes back after the refresh")

        try await clock.awaitSleepers(1)
        XCTAssertEqual(clock.sleeps, [.seconds(60), .seconds(60)], "and a minute after that")
    }

    func testAChangeWithinASecondOfTheLastThatPolledJoinsItsPoll() async throws {
        let list = RecordingPollSubscriber()
        pollers.subscribe(list, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)

        await imap.emitIdle(.exists(7), folder: Self.work)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        clock.advance(by: .seconds(1))
        await imap.emitIdle(.expunge(0), folder: Self.work)
        try await waitUntilOnMainActor { poller.changesHeard == 2 }
        XCTAssertEqual(poller.pollsRequested, 1, "a second after the last that polled: covered by it")

        clock.advance(by: .milliseconds(1))
        await imap.emitIdle(.exists(8), folder: Self.work)
        try await waitUntilOnMainActor { poller.changesHeard == 3 }
        XCTAssertEqual(poller.pollsRequested, 2, "past the second: a poll of its own")
        try await waitUntilOnMainActor { poller.pollsFinished == 2 }
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls.count, 2)
    }

    func testEveryListTakesItsTicketBeforeTheStatusAndALateJoinerSitsThePollOut() async throws {
        let first = RecordingPollSubscriber()
        pollers.subscribe(first, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)
        try await emitHoldingStatus()
        XCTAssertEqual(first.tickets.count, 1, "taken before the STATUS answered")
        XCTAssertTrue(first.released.isEmpty)

        let late = RecordingPollSubscriber()
        pollers.subscribe(late, to: Self.work, through: client)
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        XCTAssertEqual(first.handed.count, 1)
        XCTAssertTrue(late.tickets.isEmpty && late.handed.isEmpty, "it joined after the STATUS went out")
        XCTAssertEqual(poller.subscriberCount, 2)
    }

    func testAListLeavingWhileTheStatusIsOutGetsItsTicketBackOnceAndNothingElse() async throws {
        let leaving = RecordingPollSubscriber()
        let staying = RecordingPollSubscriber()
        pollers.subscribe(leaving, to: Self.work, through: client)
        pollers.subscribe(staying, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)
        try await emitHoldingStatus()

        XCTAssertNil(pollers.unsubscribe(leaving, from: Self.work, through: client), "not the last")
        XCTAssertEqual(leaving.released, leaving.tickets, "given back as it leaves")
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        XCTAssertTrue(leaving.handed.isEmpty && leaving.failures.isEmpty, "the list that left is handed nothing")
        XCTAssertEqual(leaving.released.count, 1, "and its ticket comes back once")
        XCTAssertEqual(staying.handed.count, 1)
        XCTAssertEqual(staying.released, staying.tickets)
    }

    func testAListLeavingDuringItsHandOffHasItCancelled() async throws {
        let leaving = RecordingPollSubscriber()
        let staying = RecordingPollSubscriber()
        leaving.holdsNextRefresh = true
        pollers.subscribe(leaving, to: Self.work, through: client)
        pollers.subscribe(staying, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)
        await imap.emitIdle(.exists(7), folder: Self.work)
        try await waitUntilOnMainActor { leaving.isHoldingRefresh && staying.released.count == 1 }

        pollers.unsubscribe(leaving, from: Self.work, through: client)
        XCTAssertTrue(leaving.released.isEmpty, "the hand-off owns the ticket now")
        leaving.releaseRefresh()
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }
        XCTAssertTrue(leaving.refreshWasCancelled, "leaving cancels the list's own hand-off")
        XCTAssertEqual(leaving.released, leaving.tickets, "which gives the ticket back once as it ends")
        XCTAssertEqual(poller.subscriberCount, 1)
    }

    func testOnePollRunsAtATimeHandOffsIncluded() async throws {
        let list = RecordingPollSubscriber()
        list.holdsNextRefresh = true
        pollers.subscribe(list, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)
        await imap.emitIdle(.exists(7), folder: Self.work)
        try await waitUntilOnMainActor { list.isHoldingRefresh }
        XCTAssertEqual(poller.pollsFinished, 0, "the poll waits for its hand-off")

        clock.advance(by: .seconds(2))
        await imap.emitIdle(.exists(8), folder: Self.work)
        try await waitUntilOnMainActor { poller.changesHeard == 2 }
        XCTAssertEqual(poller.pollsRequested, 2)
        let meanwhile = await imap.statusCalls
        XCTAssertEqual(meanwhile.count, 1, "the next poll waits for this one")

        list.releaseRefresh()
        try await waitUntilOnMainActor { poller.pollsFinished == 2 }
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls.count, 2)
        XCTAssertEqual(list.released, list.tickets)
    }

    func testStopAllGivesEveryTicketBackAtOnceAndALateAnswerReachesNoList() async throws {
        let first = RecordingPollSubscriber()
        let second = RecordingPollSubscriber()
        pollers.subscribe(first, to: Self.work, through: client)
        pollers.subscribe(second, to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)
        await imap.answerStatusAfterCancellation()
        try await emitHoldingStatus()

        pollers.stopAll()
        XCTAssertEqual(first.released, first.tickets, "sign-out gives every ticket back at once")
        XCTAssertEqual(second.released, second.tickets)
        XCTAssertNil(pollers.poller(for: Self.work, through: client))
        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        XCTAssertTrue(first.handed.isEmpty && second.handed.isEmpty, "an answer after the stop goes nowhere")
        XCTAssertTrue(first.failures.isEmpty && second.failures.isEmpty)
        XCTAssertEqual(first.released.count, 1, "and only once")
        try await awaitTerminations(1)
    }

    func testAPollerWhoseListsWentAwayStopsAtItsNextTickWithoutAStatus() async throws {
        var list: RecordingPollSubscriber? = RecordingPollSubscriber()
        weak var probe = list
        pollers.subscribe(try XCTUnwrap(list), to: Self.work, through: client)
        let poller = try workPoller()
        try await awaitStreams(1)

        list = nil
        XCTAssertNil(probe, "the poller holds its lists weakly")
        XCTAssertEqual(poller.subscriberCount, 0)
        try await clock.awaitSleepers(1)
        clock.fireTicks()
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        XCTAssertNil(pollers.poller(for: Self.work, through: client), "a poller with no list left stops")
        try await awaitTerminations(1)
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty, "no STATUS for nobody")
    }

    func testEachSessionsClientGetsAPollerOfItsOwnAndAnEndedOneGetsNone() async throws {
        let earlier = RecordingPollSubscriber()
        let later = RecordingPollSubscriber()
        let next = try makeClient()
        pollers.subscribe(earlier, to: Self.work, through: client)
        pollers.subscribe(later, to: Self.work, through: next)
        let ending = try workPoller()
        let current = try XCTUnwrap(pollers.poller(for: Self.work, through: next))
        XCTAssertFalse(ending === current, "a list of one session never shares another session's poller")
        try await awaitStreams(2)

        gate.markEnded(client)
        let late = RecordingPollSubscriber()
        pollers.subscribe(late, to: "Archive", through: client)
        XCTAssertNil(pollers.poller(for: "Archive", through: client), "an ended session's client polls nothing")
        pollers.subscribe(late, to: "Archive", through: next)
        XCTAssertNotNil(pollers.poller(for: "Archive", through: next))
    }

    // MARK: - Helpers

    private func workPoller() throws -> FolderPoller {
        try XCTUnwrap(pollers.poller(for: Self.work, through: client))
    }

    /// Emits a change on Work with the next STATUS held, and returns once
    /// that STATUS is parked.
    private func emitHoldingStatus(file: StaticString = #filePath, line: UInt = #line) async throws {
        let imap = imap!
        let sent = await imap.statusCalls.count
        await imap.holdNext(.status)
        await imap.emitIdle(.exists(7), folder: Self.work)
        try await awaitArrival(file: file, line: line) { await imap.statusCalls.count > sent }
        await imap.awaitHeld(.status)
    }

    private func awaitStreams(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let imap = imap!
        try await awaitArrival(file: file, line: line) { await imap.idleFolders.count >= count }
    }

    private func awaitTerminations(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let imap = imap!
        try await awaitArrival(file: file, line: line) { await imap.idleTerminations == count }
    }

    /// A client over the fake whose cache directory `tearDown` removes.
    private func makeClient() throws -> CabalmailClient {
        let made = try TestFixtures.makeClient(imap: imap)
        clients.append(made)
        return made
    }
}
