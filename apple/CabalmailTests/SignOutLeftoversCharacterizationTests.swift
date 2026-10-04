import XCTest
import CabalmailKit
@testable import Cabalmail

/// Workstream 0.8 characterization suite, with a wired session (sign-in
/// through `SessionHarness`): what `AppState.signOut()` leaves in place
/// (#1825, the form pre-fill), alongside `SignOutCharacterizationTests`,
/// which pins what it tears down. `SessionTeardownCharacterizationTests`
/// pins the same leftovers for a sign-out with no client; these show the
/// teardown past the no-client guard does not reach them either. The
/// rearchitecture (workstream 1.3) moves per-account state into a session
/// that ends as a whole, so most of these are expected to change there (the
/// preferences scope is the deliberate exception).
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

    /// Pins current behaviour, which looks like a defect: with a client too,
    /// the per-folder counts and the subscribed paths outlive the sign-out,
    /// so the next account's sidebar starts from them until its first STATUS
    /// walk and folder list land. The saved-counts bookkeeping, by contrast,
    /// is reset with a client (its seeded paths and its cache), and the badge
    /// count comes down though the sidebar's INBOX count does not.
    /// Tracked in #1825.
    func testSignOutWithAClientLeavesTheFolderCountsAndSubscriptions() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        state.setFolderCounts(folderPath: "INBOX", unread: 4, total: 30)
        state.setFolderCounts(folderPath: "Archive", unread: 3, total: 40)
        state.setSubscribedFolders(["INBOX", "Archive"])
        state.savedFolderCounts.markSeeded("Lists")
        XCTAssertEqual(state.inboxUnreadCount, 4, "precondition")

        await state.signOut()

        XCTAssertEqual(state.folderUnreadCounts, ["INBOX": 4, "Archive": 3])
        XCTAssertEqual(state.folderTotalCounts, ["INBOX": 30, "Archive": 40])
        XCTAssertEqual(state.subscribedFolderPaths, ["INBOX", "Archive"])
        XCTAssertEqual(state.inboxUnreadCount, 0)
        XCTAssertEqual(state.savedFolderCounts.seededPaths, [])
        XCTAssertNil(state.savedFolderCounts.cache)
    }

    /// Pins current behaviour, which looks like a minor defect: the removal
    /// and in-flight shields are keyed by folder path and UID, not by
    /// account, and survive the sign-out. A confirmed removal shields for a
    /// minute, so an account signing in within that window has its own
    /// INBOX UID 5 dropped by the INBOX list's refresh merges until the entry
    /// ages out (`shieldFetched` treats it as stale). A leftover in-flight
    /// move also makes the next account's Archive list withhold its STATUS
    /// counts from the sidebar until the old move resolves; the in-flight
    /// entries clear only when their write does.
    /// Tracked in #1825.
    func testSignOutWithAClientLeavesTheRemovalAndInFlightShields() async {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        state.recordConfirmedRemovals(folderPath: "INBOX", uids: [5])
        state.setFlagWrite(folderPath: "INBOX", uid: 6, inFlight: true)
        state.setMoveInFlight(folderPath: "Archive", uid: 7, inFlight: true)
        let removals = state.confirmedRemovals

        await state.signOut()

        XCTAssertEqual(state.confirmedRemovals, removals)
        XCTAssertEqual(state.confirmedRemovalUIDs(folderPath: "INBOX"), [5])
        XCTAssertEqual(state.pendingFlagWriteUIDs, ["INBOX": [6]])
        XCTAssertEqual(state.pendingMoveUIDs, ["Archive": [7]])
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
