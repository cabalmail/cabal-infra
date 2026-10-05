import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: `NavStateCoordinator`'s restore tick, the one navigation tick
/// its per-window navigation state (workstream 3.1, after defect 11,
/// window-scoped menu commands, #1783) inherits. Every launch,
/// push, Spotlight, Siri and resume-toast jump goes through `scheduleRestore`,
/// and the matching `MessageListView` picks it up through
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
        XCTAssertNil(coordinator.pendingRestore)

        coordinator.scheduleRestore(for: cursor())
        let first = try XCTUnwrap(coordinator.pendingRestore)
        XCTAssertEqual(first.folderPath, "Lists")
        XCTAssertEqual(first.messageID, "<seven@example.com>")
        XCTAssertEqual(first.uid, 7)
        XCTAssertEqual(first.listScroll, 3)

        coordinator.scheduleRestore(for: cursor())
        let second = try XCTUnwrap(coordinator.pendingRestore)
        XCTAssertGreaterThan(second.tick, first.tick)
        XCTAssertNotEqual(second, first, "a mounted list re-applies a same-folder jump")
    }

    func testAScrollRestoreIsPublishedOnlyWhenTheCursorCarriesAnOffsetOrAnAnchor() throws {
        let coordinator = try makeCoordinator()

        coordinator.scheduleRestore(for: cursor())
        XCTAssertNil(coordinator.pendingScrollRestore, "a message saved at the top is not forced back to it")

        coordinator.scheduleRestore(for: cursor(messageScroll: 640))
        let offset = try XCTUnwrap(coordinator.pendingScrollRestore)
        XCTAssertEqual(offset.offset, 640)
        XCTAssertNil(offset.anchor)
        XCTAssertEqual(offset.folderPath, "Lists")
        XCTAssertEqual(offset.uid, 7)
        XCTAssertEqual(offset.messageID, "<seven@example.com>")

        coordinator.scheduleRestore(for: cursor(messageAnchor: "i3|-4"))
        XCTAssertEqual(coordinator.pendingScrollRestore?.anchor, "i3|-4")
        XCTAssertNil(coordinator.pendingScrollRestore?.offset)

        // A fraction alone is not a scroll position on the mail path, so a
        // cursor carrying only one loses its position here. The feed path
        // does the opposite: `requestFeedNavigation` builds an `f<fraction>`
        // anchor from it. No client writes a fraction alone today (Android
        // sends one only beside an anchor), but the two paths disagree, and
        // workstream 3.1 should not standardise on this one by accident.
        coordinator.scheduleRestore(for: cursor(messageFraction: 0.5))
        XCTAssertNil(coordinator.pendingScrollRestore, "a later plain restore also clears an earlier one")
    }

    func testConsumeAnswersOnlyTheMatchingFolderAndClearsTheRestore() throws {
        let coordinator = try makeCoordinator()
        coordinator.scheduleRestore(for: cursor(messageScroll: 120))
        let scheduled = try XCTUnwrap(coordinator.pendingRestore)

        XCTAssertNil(coordinator.consumePendingRestore(for: "INBOX"))
        XCTAssertEqual(coordinator.pendingRestore, scheduled, "another folder's list leaves it for the right one")

        XCTAssertEqual(coordinator.consumePendingRestore(for: "Lists"), scheduled)
        XCTAssertNil(coordinator.pendingRestore)
        XCTAssertNil(coordinator.consumePendingRestore(for: "Lists"), "one-shot")
        XCTAssertEqual(
            coordinator.pendingScrollRestore?.offset, 120,
            "the reader consumes the scroll restore separately, once the message opens"
        )
    }

    /// The folder match is exact, unlike `AppState.isInbox`'s
    /// case-insensitive INBOX check.
    func testConsumeMatchesTheFolderPathExactly() throws {
        let coordinator = try makeCoordinator()
        coordinator.scheduleRestore(for: cursor(folder: "inbox"))

        XCTAssertNil(coordinator.consumePendingRestore(for: "INBOX"))
        XCTAssertNotNil(coordinator.consumePendingRestore(for: "inbox"))
    }

    func testClearPendingRestoreDropsBothAndTheTickKeepsCounting() throws {
        let coordinator = try makeCoordinator()
        coordinator.scheduleRestore(for: cursor(messageAnchor: "i1|0"))
        let cleared = try XCTUnwrap(coordinator.pendingRestore)

        coordinator.clearPendingRestore()
        XCTAssertNil(coordinator.pendingRestore)
        XCTAssertNil(coordinator.pendingScrollRestore)

        coordinator.scheduleRestore(for: cursor())
        let next = try XCTUnwrap(coordinator.pendingRestore)
        XCTAssertGreaterThan(next.tick, cleared.tick, "clearing does not reset the tick")
    }

    /// Pins current behaviour, which looks like an oversight: `scheduleRestore`
    /// copies every cursor field into the working cursor except
    /// `messageFraction`, so the fraction recorded for the message the user
    /// was reading rides along on the restored one until the next record.
    /// Tracked in #1826.
    func testScheduleRestorePrimesTheWorkingCursorButKeepsAStaleFraction() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.flushSession() }
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 5, messageID: "<five@example.com>")
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 5, messageID: "<five@example.com>",
            position: ReadingPosition(anchor: "i3|0", fraction: 0.4), atTop: false
        )

        coordinator.scheduleRestore(for: NavState(
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
        XCTAssertEqual(working.messageFraction, 0.4, "the old message's fraction is not")
        XCTAssertEqual(working.clientID, "this-install", "a restore is saved as this install's own")
    }
}
