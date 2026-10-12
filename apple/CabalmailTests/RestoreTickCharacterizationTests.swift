import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: the restore tick, the one navigation tick that per-window
/// navigation state inherited. Since workstream 3.3 each window parks its own
/// restores (`WindowRestores`) and the coordinator only primes the working
/// cursor (`NavStateCoordinator.primeCursor`). Every launch, push, Spotlight,
/// Siri and resume-toast jump goes through `WindowRestores.schedule`, and the
/// window's matching `MessageListView` picks it up through
/// `consumePendingRestore(for:)` once its first page lands
/// (`LaunchRestoreSequencingSourceScanTests` pins only the call order).
///
/// Nothing here touches the network: server writes stay held (the default
/// until the launch probe releases them), and the session record goes to a
/// throwaway `UserDefaults` suite.
@MainActor
final class RestoreTickCharacterizationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "RestoreTickCharacterizationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeCoordinator() throws -> NavStateCoordinator {
        NavStateCoordinator(
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            clientID: "this-install",
            store: ResumeSessionStore(defaults: defaults)
        )
    }

    private func cursor(
        folder: String = "Lists",
        messageScroll: Int? = nil,
        messageAnchor: String? = nil,
        messageFraction: Double? = nil
    ) -> NavState {
        NavState(
            folder: folder, messageID: "<seven@example.com>", uid: 7, listScroll: 3,
            messageScroll: messageScroll, messageAnchor: messageAnchor, messageFraction: messageFraction,
            clientID: "other-install"
        )
    }

    func testEachScheduleRestorePublishesAFreshTickEvenForTheSameCursor() throws {
        let coordinator = try makeCoordinator()
        let restores = WindowRestores()
        XCTAssertNil(restores.pendingRestore)

        restores.schedule(cursor(), priming: coordinator)
        let first = try XCTUnwrap(restores.pendingRestore)
        XCTAssertEqual(first.folderPath, "Lists")
        XCTAssertEqual(first.messageID, "<seven@example.com>")
        XCTAssertEqual(first.uid, 7)
        XCTAssertEqual(first.listScroll, 3)

        restores.schedule(cursor(), priming: coordinator)
        let second = try XCTUnwrap(restores.pendingRestore)
        XCTAssertGreaterThan(second.tick, first.tick)
        XCTAssertNotEqual(second, first, "a mounted list re-applies a same-folder jump")
    }

    func testAScrollRestoreIsPublishedOnlyWhenTheCursorCarriesAnOffsetOrAnAnchor() throws {
        let coordinator = try makeCoordinator()
        let restores = WindowRestores()

        restores.schedule(cursor(), priming: coordinator)
        XCTAssertNil(restores.pendingScrollRestore, "a message saved at the top is not forced back to it")

        restores.schedule(cursor(messageScroll: 640), priming: coordinator)
        let offset = try XCTUnwrap(restores.pendingScrollRestore)
        XCTAssertEqual(offset.offset, 640)
        XCTAssertNil(offset.anchor)
        XCTAssertEqual(offset.folderPath, "Lists")
        XCTAssertEqual(offset.uid, 7)
        XCTAssertEqual(offset.messageID, "<seven@example.com>")

        restores.schedule(cursor(messageAnchor: "i3|-4"), priming: coordinator)
        XCTAssertEqual(restores.pendingScrollRestore?.anchor, "i3|-4")
        XCTAssertNil(restores.pendingScrollRestore?.offset)

        // A fraction alone is not a scroll position on the mail path, so a
        // cursor carrying only one loses its position here. The feed path
        // does the opposite: `requestFeedNavigation` builds an `f<fraction>`
        // anchor from it. No client writes a fraction alone today (Android
        // sends one only beside an anchor), but the two paths disagree, and
        // workstream 3.1 should not standardise on this one by accident.
        restores.schedule(cursor(messageFraction: 0.5), priming: coordinator)
        XCTAssertNil(restores.pendingScrollRestore, "a later plain restore also clears an earlier one")
    }

    func testConsumeAnswersOnlyTheMatchingFolderAndClearsTheRestore() throws {
        let coordinator = try makeCoordinator()
        let restores = WindowRestores()
        restores.schedule(cursor(messageScroll: 120), priming: coordinator)
        let scheduled = try XCTUnwrap(restores.pendingRestore)

        XCTAssertNil(restores.consumePendingRestore(for: "INBOX"))
        XCTAssertEqual(restores.pendingRestore, scheduled, "another folder's list leaves it for the right one")

        XCTAssertEqual(restores.consumePendingRestore(for: "Lists"), scheduled)
        XCTAssertNil(restores.pendingRestore)
        XCTAssertNil(restores.consumePendingRestore(for: "Lists"), "one-shot")
        XCTAssertEqual(
            restores.pendingScrollRestore?.offset, 120,
            "the reader consumes the scroll restore separately, once the message opens"
        )
    }

    /// The folder match is exact, unlike `MailCounts.isInbox`'s
    /// case-insensitive INBOX check.
    func testConsumeMatchesTheFolderPathExactly() throws {
        let coordinator = try makeCoordinator()
        let restores = WindowRestores()
        restores.schedule(cursor(folder: "inbox"), priming: coordinator)

        XCTAssertNil(restores.consumePendingRestore(for: "INBOX"))
        XCTAssertNotNil(restores.consumePendingRestore(for: "inbox"))
    }

    func testClearPendingRestoreDropsBothAndTheTickKeepsCounting() throws {
        let coordinator = try makeCoordinator()
        let restores = WindowRestores()
        restores.schedule(cursor(messageAnchor: "i1|0"), priming: coordinator)
        let cleared = try XCTUnwrap(restores.pendingRestore)

        restores.clearPendingRestore()
        XCTAssertNil(restores.pendingRestore)
        XCTAssertNil(restores.pendingScrollRestore)

        restores.schedule(cursor(), priming: coordinator)
        let next = try XCTUnwrap(restores.pendingRestore)
        XCTAssertGreaterThan(next.tick, cleared.tick, "clearing does not reset the tick")
    }

    /// `primeCursor` primes every working-cursor field from the cursor,
    /// `messageFraction` included, so the fraction recorded for the message
    /// the user was reading doesn't ride along on the restored one. Until
    /// #1826 it skipped the fraction and this pinned the stale value.
    func testScheduleRestorePrimesEveryWorkingCursorFieldIncludingTheFraction() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.flushSession() }
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 5, messageID: "<five@example.com>")
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 5, messageID: "<five@example.com>",
            position: ReadingPosition(anchor: "i3|0", fraction: 0.4), atTop: false
        )
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.4, "precondition: the message left has one")

        coordinator.primeCursor(for: NavState(
            folder: "Archive", messageID: "<nine@example.com>", uid: 9, uidValidity: 77,
            listScroll: 2, messageScroll: 120, clientID: "other-install"
        ))

        let working = try XCTUnwrap(coordinator.workingCursor)
        XCTAssertEqual(working.folder, "Archive")
        XCTAssertEqual(working.messageID, "<nine@example.com>")
        XCTAssertEqual(working.uid, 9)
        XCTAssertEqual(working.uidValidity, 77)
        XCTAssertEqual(working.listScroll, 2)
        XCTAssertEqual(working.messageScroll, 120)
        XCTAssertNil(working.messageAnchor, "the old message's anchor is replaced")
        XCTAssertNil(working.messageFraction, "so is its fraction")
        XCTAssertNil(working.requestBody["msg_fraction"])
        XCTAssertEqual(working.clientID, "this-install", "a restore is saved as this install's own")

        coordinator.primeCursor(for: NavState(
            folder: "Archive", messageID: "<nine@example.com>", uid: 9,
            messageAnchor: "f0.6500", messageFraction: 0.65, clientID: "other-install"
        ))
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.65, "a cursor's own fraction is primed")
    }

    /// #1873: a restore primes the cursor's UIDVALIDITY. The list selecting
    /// the restored message records it again and keeps it; opening any other
    /// message, in that folder or another, clears it rather than echoing a
    /// value that was never that message's.
    func testARestoredUIDValidityStaysOnlyWithTheRestoredMessage() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.flushSession() }
        coordinator.primeCursor(for: NavState(
            folder: "Archive", messageID: "<nine@example.com>", uid: 9, uidValidity: 77,
            clientID: "other-install"
        ))

        coordinator.recordMessage(folderPath: "Archive", uid: 9, messageID: "<nine@example.com>")
        XCTAssertEqual(coordinator.workingCursor?.uidValidity, 77, "the restored message keeps it")

        coordinator.recordMessage(folderPath: "Archive", uid: 12, messageID: "<twelve@example.com>")
        XCTAssertEqual(coordinator.workingCursor?.uid, 12)
        XCTAssertNil(coordinator.workingCursor?.uidValidity, "another message in the same folder drops it")

        coordinator.primeCursor(for: NavState(
            folder: "Archive", messageID: "<nine@example.com>", uid: 9, uidValidity: 77,
            clientID: "other-install"
        ))
        coordinator.recordMessage(folderPath: "INBOX", uid: 9, messageID: "<inbox-nine@example.com>")
        XCTAssertNil(coordinator.workingCursor?.uidValidity, "the same UID in another folder drops it too")
    }

    /// Closing the restored message (back to its list) leaves a folder
    /// cursor with no reading fraction, matching the offset and anchor it
    /// already cleared. (The folder's UIDVALIDITY may stay: it is the
    /// folder's, and the next message opened clears it.)
    func testClosingTheMessageClearsItsFraction() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.flushSession() }
        coordinator.primeCursor(for: NavState(
            folder: "Archive", messageID: "<nine@example.com>", uid: 9, uidValidity: 77,
            messageAnchor: "i2|0", messageFraction: 0.3, clientID: "other-install"
        ))

        coordinator.recordNoMessage(folderPath: "Archive")

        let working = try XCTUnwrap(coordinator.workingCursor)
        XCTAssertEqual(working.folder, "Archive")
        XCTAssertNil(working.uid)
        XCTAssertNil(working.messageID)
        XCTAssertNil(working.messageAnchor)
        XCTAssertNil(working.messageFraction)
        XCTAssertNil(working.requestBody["msg_fraction"])
    }
}
