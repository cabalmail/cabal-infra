import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The Inbox badge poller's STATUS can be back from the server, and only
/// waiting to resume on the main actor, when a sign-out stops the poller and
/// resets the badge to 0. That poll used to write the ended account's count
/// back over the reset, where it stayed on the app badge and the macOS
/// menu-bar count until the next session's first poll (#1886).
///
/// The race tests park the poller's first STATUS, end its loop while it
/// waits, then let the STATUS answer as if its reply had arrived before the
/// cancel (`answerStatusAfterCancellation`), and await the loop's last tick.
@MainActor
final class InboxBadgePollerTests: XCTestCase {
    private var writes: [Int] = []
    /// What the pollers read as the session's client.
    private var sessionClient: CabalmailClient?

    override func setUp() async throws {
        writes = []
        sessionClient = nil
    }

    /// The control: an uninterrupted poll writes the count it fetched.
    func testAPollWritesTheInboxCount() async throws {
        let imap = await heldInbox(unseen: 7)
        let pollers = makePollers(client: try TestFixtures.makeClient(imap: imap))
        let loop = try XCTUnwrap(startPolling(pollers))
        await imap.awaitHeld(.status)

        await imap.releaseHeld(.status)
        try await waitUntilOnMainActor { self.writes == [7] }

        loop.cancel()
        await loop.value
    }

    func testAPollAnsweringAfterTheStopLeavesTheBadgeReset() async throws {
        let imap = await heldInbox(unseen: 7)
        let pollers = makePollers(client: try TestFixtures.makeClient(imap: imap))
        let loop = try XCTUnwrap(startPolling(pollers))
        await imap.awaitHeld(.status)

        pollers.stopInboxBadgePolling()
        await imap.releaseHeld(.status)
        await loop.value

        XCTAssertEqual(writes, [0], "only the stop's reset; the ended session's 7 is dropped")
        let statusCalls = await imap.statusCalls.count
        XCTAssertEqual(statusCalls, 1, "precondition: the poll did reach STATUS")
    }

    /// Account switch: the next session's poller is already running when
    /// the last session's held poll answers. Only the new account's count
    /// reaches the badge.
    func testAPollAnsweringAfterTheNextSessionStartedLeavesTheNewCount() async throws {
        let oldImap = await heldInbox(unseen: 7)
        let pollers = makePollers(client: try TestFixtures.makeClient(imap: oldImap))
        let oldLoop = try XCTUnwrap(startPolling(pollers))
        await oldImap.awaitHeld(.status)

        pollers.stopInboxBadgePolling()
        let newImap = FakeImapClient()
        await newImap.scriptStatusResults([.success(FolderStatus(unseen: 2))])
        sessionClient = try TestFixtures.makeClient(imap: newImap)
        let newLoop = try XCTUnwrap(startPolling(pollers))
        try await waitUntilOnMainActor { self.writes == [0, 2] }

        await oldImap.releaseHeld(.status)
        await oldLoop.value

        XCTAssertEqual(writes, [0, 2], "the old account's 7 never lands after the new account's 2")
        newLoop.cancel()
        await newLoop.value
    }

    // MARK: - Helpers

    /// An INBOX whose next STATUS reports `unseen` and parks until released,
    /// then answers even if its poller was cancelled meanwhile.
    private func heldInbox(unseen: Int) async -> FakeImapClient {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(unseen: unseen))])
        await imap.holdNext(.status)
        await imap.answerStatusAfterCancellation()
        return imap
    }

    private func makePollers(client: CabalmailClient) -> SessionPollers {
        sessionClient = client
        let pollers = SessionPollers()
        pollers.client = { [weak self] in self?.sessionClient }
        pollers.inboxUnreadChanged = { [weak self] in self?.writes.append($0) }
        return pollers
    }

    private func startPolling(_ pollers: SessionPollers) -> Task<Void, Never>? {
        pollers.startInboxBadgePolling(requestAuthorization: {})
        return pollers.inboxBadgeTask
    }
}
