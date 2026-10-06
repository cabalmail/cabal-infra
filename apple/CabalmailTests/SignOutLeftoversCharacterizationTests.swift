import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Workstream 0.8 characterization suite, with a wired session (sign-in
/// through `SessionHarness`): what `AppState.signOut()` leaves in place (the
/// form pre-fill, the command ticks, the preferences scope) and the
/// per-account state it now clears (#1825), alongside
/// `SignOutCharacterizationTests`, which pins what it tears down.
/// `SessionTeardownCharacterizationTests` pins the same for a sign-out with
/// no client. The rearchitecture (workstream 1.3) moves per-account state
/// into a session that ends as a whole, so the leftovers are expected to
/// change there (the preferences scope is the deliberate exception).
@MainActor
final class SignOutLeftoversCharacterizationTests: XCTestCase {
    private var harness: SessionHarness!

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    /// The control domain and username stay in the last-session defaults so
    /// the sign-in form pre-fills; sign-out neither clears nor republishes
    /// them.
    func testSignOutKeepsTheLastSessionForTheFormPrefill() async {
        await SignOutSuiteSteps.signIn(harness)
        let mark = harness.events.count

        await harness.appState.signOut()

        XCTAssertEqual(harness.appState.controlDomain, "cabalmail.example")
        XCTAssertEqual(harness.appState.lastUsername, "alice")
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.lastUsername"), "alice")
        XCTAssertEqual(Array(harness.events[mark...]), ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
    }

    /// The per-folder counts and the subscribed paths go with the session,
    /// along with the saved-counts bookkeeping and the badge count (#1825).
    /// They used to outlive it, so the next account's sidebar started from
    /// them until its first STATUS walk and folder list landed.
    func testSignOutWithAClientClearsTheFolderCountsAndSubscriptions() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        state.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 4, total: 30)
        state.mailStore.counts.setFolderCounts(folderPath: "Archive", unread: 3, total: 40)
        state.mailStore.counts.setSubscribedFolders(["INBOX", "Archive"])
        state.mailStore.counts.savedFolderCounts.markSeeded("Lists")
        XCTAssertEqual(state.mailStore.counts.inboxUnreadCount, 4, "precondition")

        await state.signOut()

        XCTAssertEqual(state.mailStore.counts.folderUnreadCounts, [:])
        XCTAssertEqual(state.mailStore.counts.folderTotalCounts, [:])
        XCTAssertNil(state.mailStore.counts.subscribedFolderPaths)
        XCTAssertEqual(state.mailStore.counts.inboxUnreadCount, 0)
        XCTAssertEqual(state.mailStore.counts.savedFolderCounts.seededPaths, [])
        XCTAssertNil(state.mailStore.counts.savedFolderCounts.cache)
    }

    /// The removal and in-flight shields are keyed by folder path and UID,
    /// not by account, so they go with the session (#1825). Surviving it, a
    /// confirmed removal shielded for a minute, so an account signing in
    /// within that window had its own INBOX UID 5 dropped by the INBOX
    /// list's refresh merges until the entry aged out, and a leftover
    /// in-flight move made the next account's Archive list withhold its
    /// STATUS counts from the sidebar until the old move resolved.
    func testSignOutWithAClientClearsTheRemovalAndInFlightShields() async {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let removed = MessageRef(folder: "INBOX", uid: 5)
        state.recordConfirmedRemovals([removed])
        state.setFlagWrite(MessageRef(folder: "INBOX", uid: 6), inFlight: true)
        state.setMoveInFlight(MessageRef(folder: "Archive", uid: 7), inFlight: true)
        XCTAssertEqual(state.confirmedRemovalRefs(folderPath: "INBOX"), [removed], "precondition")

        await state.signOut()

        XCTAssertEqual(state.confirmedRemovals, [:])
        XCTAssertEqual(state.confirmedRemovalRefs(folderPath: "INBOX"), [])
        XCTAssertEqual(state.pendingFlagWriteRefs, [])
        XCTAssertEqual(state.pendingMoveRefs, [])
    }

    /// Every reader's attachment folder goes with the session (#1813). Each
    /// reader writes its own, and Forward reads the files after the reader
    /// has closed, so sign-out is where they are removed; until then the OS
    /// swept them only between launches, and the next account could open the
    /// last one's files. Other temp files stay.
    func testSignOutRemovesEveryReadersAttachmentFolder() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let manager = FileManager.default
        let readers = [AttachmentFolders.make(), AttachmentFolders.make()]
        for folder in readers {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("scan".utf8).write(to: folder.appendingPathComponent("scan.pdf"))
        }
        let other = manager.temporaryDirectory.appendingPathComponent("not-an-attachment-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: other)
        defer { try? manager.removeItem(at: other) }

        await harness.appState.signOut()

        for folder in readers {
            XCTAssertFalse(manager.fileExists(atPath: folder.path), folder.lastPathComponent)
        }
        XCTAssertTrue(manager.fileExists(atPath: other.path))
    }

    /// With a client as without one, the command ticks, their window target
    /// and the parked compose seed are left alone.
    func testSignOutWithAClientLeavesTheCommandTicksAlone() async {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let window = UUID()
        let seed = Draft(subject: "parked by a mailto: link")
        state.requestRefresh()
        state.requestReply()
        state.requestToggleSeen()
        state.requestFeedCommand(.refresh)
        state.requestCompose(seed: seed, in: window)
        let ticks = Self.ticks(of: state)
        XCTAssertFalse(ticks.contains(0), "precondition: every tick was bumped")

        await state.signOut()

        XCTAssertEqual(Self.ticks(of: state), ticks)
        XCTAssertEqual(state.commandWindow, window)
        XCTAssertEqual(state.pendingComposeSeed, seed)
        XCTAssertEqual(state.pendingFeedCommand, .refresh)
    }

    /// Sign-out leaves the app's `Preferences` scoped to the account that
    /// left; the next `wireSession` re-activates them for whoever signs in.
    /// This is documented intent, not a leftover to fix: `Preferences.activate`
    /// says sign-out "deliberately leaves the last scope active so the
    /// signed-out UI (theme, the macOS Settings scene) doesn't snap to
    /// defaults". A session manager that ends per-account state as a whole
    /// should keep it.
    func testSignOutLeavesThePreferencesOnTheAccountThatLeft() async {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        harness.appState.usePreferences(preferences)
        await SignOutSuiteSteps.signIn(harness)
        let scope = preferences.accountScope
        XCTAssertNotNil(scope, "precondition")

        await harness.appState.signOut()

        XCTAssertEqual(preferences.accountScope, scope)
    }

    private static func ticks(of state: AppState) -> [Int] {
        [state.composeRequestTick, state.refreshRequestTick, state.replyRequestTick,
         state.toggleSeenRequestTick, state.feedCommandTick]
    }
}
