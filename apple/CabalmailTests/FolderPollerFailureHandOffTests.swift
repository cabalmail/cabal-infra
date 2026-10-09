import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A failed poll's hand-off to a list that has left the folder's poller by
/// the time the hand-off runs (2.2 D). The hand-offs are queued on the main
/// actor after the STATUS fails, so a list can leave between the failure and
/// its own hand-off, for example as a reader is pushed over it. Its hand-off
/// is cancelled then, and a failure must not reach it: no error line on a
/// list that has gone, and no search re-run for it.
@MainActor
final class FolderPollerFailureHandOffTests: XCTestCase {
    private static let work = "Work"

    private var imap: FakeImapClient!
    private var pollers: FolderPollers!
    private var client: CabalmailClient!

    override func setUp() async throws {
        imap = FakeImapClient()
        await imap.scriptIdle()
        pollers = FolderPollers(teardownGate: SessionTeardownGate())
        ManualPollClock().install(on: pollers)
        client = try TestFixtures.makeClient(imap: imap)
    }

    override func tearDown() async throws {
        pollers.stopAll()
        let root = await client.bodyCache.directory.deletingLastPathComponent()
        if root.lastPathComponent.hasPrefix("cabalmail-tests-") { try? FileManager.default.removeItem(at: root) }
    }

    func testAListThatLeavesBeforeItsHandOffOfAFailedPollRunsIsToldNothing() async throws {
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let staying = RecordingPollSubscriber()
        let leaving = RecordingPollSubscriber()
        pollers.subscribe(staying, to: Self.work, through: client)
        pollers.subscribe(leaving, to: Self.work, through: client)
        let poller = try XCTUnwrap(pollers.poller(for: Self.work, through: client))
        // The first hand-off runs first, and takes the second list off before
        // the second hand-off has started.
        let pollers = pollers!
        let client = client!
        staying.onFailure = { pollers.unsubscribe(leaving, from: Self.work, through: client) }
        let imap = imap!
        try await awaitArrival { await imap.idleFolders.count >= 1 }

        await imap.emitIdle(.exists(7), folder: Self.work)
        try await waitUntilOnMainActor { poller.pollsFinished == 1 }

        XCTAssertEqual(staying.failures.count, 1, "the list still on the poller is told")
        XCTAssertEqual(leaving.tickets.count, 1, "precondition: the leaving list was in the poll")
        XCTAssertTrue(leaving.failures.isEmpty, "a failure reaches no list that has left")
        XCTAssertEqual(leaving.released, leaving.tickets, "and its ticket comes back once")
    }
}
