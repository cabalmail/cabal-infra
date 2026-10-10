import XCTest
import CoreSpotlight
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the rearchitecture proposal,
/// second half (the first is `SessionLifecycleCharacterizationTests`): where a
/// Spotlight tap waits while no session is wired, and what a sign-out with no
/// client stops, clears (#1825) and leaves behind (#1703). The refactor moves
/// all of this into a per-account session, so these record it as it is today.
///
/// A sign-out with no client is the first part of every sign-out, and it is
/// also reachable on its own: the macOS Settings scene is always available,
/// and Settings ▸ Account ▸ Sign Out has no status check, so it runs while
/// signed out, on the code form, or in `.error`. Every test runs with no
/// client: `signOut()`'s teardown past its no-client guard reaches push
/// registration, the keychain and the Spotlight index, so it needs a session
/// seam before it can be pinned here.
@MainActor
final class SessionTeardownCharacterizationTests: XCTestCase {
    private static let mismatch = "That code did not match. Please try again."
    private let parked = SpotlightMessageRef(folder: "Archive/2026", uid: 4242)
    private let later = SpotlightMessageRef(folder: "INBOX", uid: 7)

    // MARK: - Spotlight parking while no session is wired

    func testASpotlightTapBeforeASessionParksTheRef() {
        let state = AppState()
        state.routeSpotlightRef(parked)
        XCTAssertEqual(state.deepLinks.parked, .spotlight(parked))
    }

    /// One slot: the latest tap wins.
    func testALaterTapReplacesTheParkedRef() {
        let state = AppState()
        state.routeSpotlightRef(parked)
        state.routeSpotlightRef(later)
        XCTAssertEqual(state.deepLinks.parked, .spotlight(later))
    }

    func testASpotlightActivityBeforeASessionParksItsRef() {
        let state = AppState()
        state.handleSpotlightActivity(Self.activity(identifier: parked.stringValue))
        XCTAssertEqual(state.deepLinks.parked, .spotlight(parked))
    }

    func testAnActivityThatIsNotOursParksNothing() {
        let state = AppState()
        state.handleSpotlightActivity(Self.activity(identifier: "com.example.other|4242"))
        state.handleSpotlightActivity(NSUserActivity(activityType: CSSearchableItemActionType))
        XCTAssertNil(state.deepLinks.parked)
    }

    /// Nothing replays a parked ref at session start any more: it waits in
    /// the router for a window. A window with no session to open it in
    /// hands it straight back, so it stays parked.
    func testAWindowWithNoSessionLeavesTheRefParked() {
        let state = AppState()
        state.routeSpotlightRef(parked)
        let window = SceneNavigator(
            coordinator: { nil }, hasClient: { false }, seed: .mail, deepLinks: state.deepLinks
        )
        window.windowID = UUID()

        state.deepLinks.register(window)

        XCTAssertEqual(state.deepLinks.parked, .spotlight(parked))
    }

    /// The slot is not tied to an account, so a sign-out drops what it holds
    /// rather than replay it into whichever account signs in next (#1825).
    /// Waiting for a session is the slot's documented job (the cold-launch
    /// handoff); a sign-out ends the wait. A different-user sign-in drops a
    /// ref parked after it (`SpotlightSignInTests`).
    func testSignOutWithNoClientDropsTheParkedRef() async {
        let state = AppState()
        state.sessionManager.status = .signingIn
        state.routeSpotlightRef(parked)

        await state.signOut()

        XCTAssertNil(state.deepLinks.parked)
    }

    /// An expiry ends the wait through the same teardown.
    func testAnExpiryDropsTheParkedRef() async {
        let state = AppState()
        state.sessionManager.status = .signedIn
        state.routeSpotlightRef(parked)
        XCTAssertEqual(state.deepLinks.parked, .spotlight(parked), "precondition: no session is wired")

        await state.sessionManager.handleSessionExpiry()

        XCTAssertNil(state.deepLinks.parked)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
    }

    // MARK: - What a sign-out with no client stops, and what it leaves

    /// The work before the no-client guard runs on every sign-out.
    func testSignOutWithNoClientStillStopsThePollersAndClearsTheReason() async {
        let state = AppState()
        state.sessionManager.status = .signedIn
        state.sessionManager.signedOutReason = .sessionExpired
        state.mailStore.counts.applyUnreadDelta(folderPath: "INBOX", delta: 2)
        let feedPoll = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
        defer { feedPoll.cancel() }
        state.sessionManager.pollers.feedRefreshTask = feedPoll
        XCTAssertEqual(state.mailStore.counts.inboxUnreadCount, 2, "precondition")

        await state.signOut()

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.signedOutReason, "a deliberate sign-out explains nothing")
        XCTAssertEqual(state.mailStore.counts.inboxUnreadCount, 0, "the badge count comes down")
        XCTAssertTrue(feedPoll.isCancelled, "the feed poller stops")
        XCTAssertNil(state.sessionManager.pollers.feedRefreshTask)
        // The sidebar's INBOX count comes down with the badge count (#1825).
        // The next session used to start from it until its STATUS walk, and
        // `FolderListViewModel.seedSavedCounts` seeds only a folder whose
        // count is nil, so offline it also blocked that seed.
        XCTAssertNil(state.mailStore.counts.folderUnreadCounts["INBOX"])
    }

    /// The folder counts, the subscribed paths and the saved-counts
    /// bookkeeping go with every sign-out, client or not (#1825). They used
    /// to outlive it, so the next account's sidebar started from them until
    /// its first STATUS walk and folder list landed.
    ///
    /// The toast survives, which is not a defect: every production writer
    /// goes through `showToast`, which clears it after 4-10 s, and only
    /// `SignedInRootView` draws it. It could reappear only if the user signed
    /// back in within that window. The long duration here keeps the timer
    /// from racing the assertion.
    func testSignOutWithNoClientClearsTheFolderStateButLeavesTheToast() async {
        let state = AppState()
        state.sessionManager.status = .signedIn
        state.mailStore.counts.folderUnreadCounts = ["Archive": 3]
        state.mailStore.counts.folderTotalCounts = ["Archive": 40]
        state.mailStore.counts.setSubscribedFolders(["INBOX", "Archive"])
        state.mailStore.counts.savedFolderCounts.markSeeded("Archive")
        let toast = Toast(kind: .info, message: "Message queued — will send when back online")
        state.showToast(toast, duration: 3600)

        await state.signOut()

        XCTAssertEqual(state.mailStore.counts.folderUnreadCounts, [:])
        XCTAssertEqual(state.mailStore.counts.folderTotalCounts, [:])
        XCTAssertNil(state.mailStore.counts.subscribedFolderPaths)
        XCTAssertEqual(state.mailStore.counts.savedFolderCounts.seededPaths, [])
        XCTAssertEqual(state.toast, toast, "sign-out leaves the toast to its own timer")
    }

    /// The command ticks, their window target and the one-shot handoffs. The
    /// refactor replaces the ticks with focused-window commands; today a
    /// sign-out never resets any of them. The reader's mail events (a failed
    /// removal, a dispose) were delivered when posted, and a sign-out
    /// neither posts another nor takes them back.
    func testSignOutWithNoClientLeavesTheCommandsAndHandoffsAlone() async {
        let state = AppState()
        let window = UUID()
        let seed = Draft(subject: "parked by a mailto: link")
        state.sessionManager.status = .signedIn
        let events = MailEventRecorder(state.mailStore)
        Self.bumpEveryCommand(on: state, seed: seed, window: window)
        let ticks = Self.ticks(of: state)
        XCTAssertFalse(ticks.contains(0), "precondition: every tick was bumped")
        let posted = events.events
        let move = state.pendingMoveRequest

        await state.signOut()

        XCTAssertEqual(Self.ticks(of: state), ticks)
        XCTAssertEqual(state.commandWindow, window)
        XCTAssertEqual(state.lastActiveMainWindow, window)
        XCTAssertEqual(state.pendingComposeSeed, seed)
        XCTAssertEqual(state.pendingFeedCommand, .refresh)
        XCTAssertEqual(state.pendingSidebarTreeCommand, .expandAllFolders)
        let expected: [MailEvent.Change] = [
            .restored(MessageRef(folder: "INBOX", uid: 8), markUnread: false),
            .removed([MessageRef(folder: "INBOX", uid: 9)]),
        ]
        XCTAssertEqual(posted.map(\.change), expected, "precondition: both mail events were posted")
        XCTAssertEqual(events.events, posted, "sign-out posts no mail event")
        XCTAssertNotNil(move)
        XCTAssertEqual(state.pendingMoveRequest, move)
    }

    /// The Settings ▸ Account path from the code form: `signOut()` never
    /// touches `mfaError`, so the form's error survives. Unseen today: the
    /// password form does not show it, and `signIn` clears it.
    func testSignOutFromTheCodeFormLeavesItsErrorBehind() async {
        let state = AppState()
        state.sessionManager.status = .mfaCodeRequired(.totp)
        state.sessionManager.mfaError = Self.mismatch

        await state.signOut()

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.mfaError, Self.mismatch)
        XCTAssertNil(state.signedOutReason)
    }

    // MARK: - Helpers

    private static func bumpEveryCommand(on state: AppState, seed: Draft, window: UUID) {
        state.requestRefresh()
        state.requestReply()
        state.requestReplyAll()
        state.requestForward()
        state.requestToggleSeen()
        state.requestToggleFlagged()
        state.requestMoveSelection()
        state.requestMarkFolderRead()
        state.requestFeedCommand(.refresh)
        state.requestSidebarTree(.expandAllFolders)
        state.requestMove(items: [MessageDragItem(uid: 9, sourceFolder: "INBOX")], to: "Archive", from: nil)
        state.mailStore.events.post(.restored(MessageRef(folder: "INBOX", uid: 8), markUnread: false), from: nil)
        state.mailStore.events.post(.removed([MessageRef(folder: "INBOX", uid: 9)]), from: nil)
        state.requestSettings()
        state.noteActiveMainWindow(window)
        // Last, so its window is the recorded target.
        state.requestCompose(seed: seed, in: window)
    }

    private static func ticks(of state: AppState) -> [Int] {
        [
            state.composeRequestTick, state.refreshRequestTick, state.replyRequestTick,
            state.replyAllRequestTick, state.forwardRequestTick, state.toggleSeenRequestTick,
            state.toggleFlaggedRequestTick, state.moveSelectionRequestTick, state.markFolderReadRequestTick,
            state.settingsRequestTick, state.feedCommandTick, state.sidebarTreeCommandTick,
            state.moveRequestTick,
        ]
    }

    private static func activity(identifier: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        return activity
    }
}
