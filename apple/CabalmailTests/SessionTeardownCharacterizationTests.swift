import XCTest
import CoreSpotlight
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 of the rearchitecture proposal,
/// second half (the first is `SessionLifecycleCharacterizationTests`): where a
/// Spotlight tap waits while no session is wired, and what a sign-out with no
/// client stops and leaves behind (#1703). The refactor moves all of this
/// into a per-account session, so these record it as it is today.
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
        XCTAssertEqual(state.pendingSpotlightRef, parked)
    }

    /// One slot: the latest tap wins.
    func testALaterTapReplacesTheParkedRef() {
        let state = AppState()
        state.routeSpotlightRef(parked)
        state.routeSpotlightRef(later)
        XCTAssertEqual(state.pendingSpotlightRef, later)
    }

    func testASpotlightActivityBeforeASessionParksItsRef() {
        let state = AppState()
        state.handleSpotlightActivity(Self.activity(identifier: parked.stringValue))
        XCTAssertEqual(state.pendingSpotlightRef, parked)
    }

    func testAnActivityThatIsNotOursParksNothing() {
        let state = AppState()
        state.handleSpotlightActivity(Self.activity(identifier: "com.example.other|4242"))
        state.handleSpotlightActivity(NSUserActivity(activityType: CSSearchableItemActionType))
        XCTAssertNil(state.pendingSpotlightRef)
    }

    /// The replay `wireSession` runs clears the slot and routes again, and
    /// with no session that parks the ref straight back.
    func testReplayingWithNoSessionParksTheRefAgain() {
        let state = AppState()
        state.routeSpotlightRef(parked)
        state.routePendingSpotlightOpen()
        XCTAssertEqual(state.pendingSpotlightRef, parked)
    }

    /// Pins current behaviour, which may be a minor defect: neither `signOut()`
    /// nor `handleSessionExpiry()` clears the slot, which is not tied to an
    /// account, so the parked ref is replayed into whichever account signs in
    /// next. Waiting for a session is the slot's documented job (the
    /// cold-launch handoff). A sign-out with a client also clears the
    /// Spotlight index, so a tap for another account mostly arises after a
    /// force-quit or a failed restore; a no-client sign-out that keeps the ref
    /// is reachable from macOS Settings while signed out.
    /// Tracked in #1825.
    func testSignOutWithNoClientKeepsTheParkedRef() async {
        let state = AppState()
        state.status = .restoring
        state.routeSpotlightRef(parked)

        await state.signOut()
        XCTAssertEqual(state.pendingSpotlightRef, parked, "a deliberate sign-out keeps it")

        state.status = .signedIn
        await state.handleSessionExpiry()
        XCTAssertEqual(state.pendingSpotlightRef, parked, "an expiry keeps it")
    }

    // MARK: - What a sign-out with no client stops, and what it leaves

    /// The work before the no-client guard runs on every sign-out.
    func testSignOutWithNoClientStillStopsThePollersAndClearsTheReason() async {
        let state = AppState()
        state.status = .signedIn
        state.signedOutReason = .sessionExpired
        state.applyUnreadDelta(folderPath: "INBOX", delta: 2)
        let feedPoll = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
        defer { feedPoll.cancel() }
        state.feedRefreshTask = feedPoll
        XCTAssertEqual(state.inboxUnreadCount, 2, "precondition")

        await state.signOut()

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.signedOutReason, "a deliberate sign-out explains nothing")
        XCTAssertEqual(state.inboxUnreadCount, 0, "the badge count comes down")
        XCTAssertTrue(feedPoll.isCancelled, "the feed poller stops")
        XCTAssertNil(state.feedRefreshTask)
        // Pins current behaviour, which looks like a defect: the sidebar's
        // INBOX count is not reset with the badge count. Nothing shows it
        // while signed out, but the next session starts from it until its
        // STATUS walk, and `FolderListViewModel.seedSavedCounts` only seeds a
        // folder whose count is nil, so offline it also blocks that seed.
        XCTAssertEqual(state.folderUnreadCounts["INBOX"], 2)
    }

    /// Pins current behaviour, which looks like a defect: the folder counts
    /// and the subscribed paths outlive a sign-out. With a client too: the
    /// teardown past the guard resets `savedFolderCounts` but not these, so
    /// the next account's sidebar starts from them until its first STATUS
    /// walk and folder list land.
    ///
    /// The toast also survives, but that is not a defect: every production
    /// writer goes through `showToast`, which clears it after 4-10 s, and only
    /// `SignedInRootView` draws it. It could reappear only if the user signed
    /// back in within that window. The long duration here keeps the timer
    /// from racing the assertion.
    /// Tracked in #1825.
    func testSignOutWithNoClientLeavesTheFolderStateAndToastInPlace() async {
        let state = AppState()
        state.status = .signedIn
        state.folderUnreadCounts = ["Archive": 3]
        state.folderTotalCounts = ["Archive": 40]
        state.setSubscribedFolders(["INBOX", "Archive"])
        state.savedFolderCounts.markSeeded("Archive")
        let toast = Toast(kind: .info, message: "Message queued — will send when back online")
        state.showToast(toast, duration: 3600)

        await state.signOut()

        XCTAssertEqual(state.folderUnreadCounts, ["Archive": 3])
        XCTAssertEqual(state.folderTotalCounts, ["Archive": 40])
        XCTAssertEqual(state.subscribedFolderPaths, ["INBOX", "Archive"])
        XCTAssertEqual(state.savedFolderCounts.seededPaths, ["Archive"], "reset only with a client")
        XCTAssertEqual(state.toast, toast, "sign-out leaves the toast to its own timer")
    }

    /// The command ticks, their window target and the one-shot handoffs. The
    /// refactor replaces the ticks with focused-window commands; today a
    /// sign-out never resets any of them.
    func testSignOutWithNoClientLeavesTheCommandsAndHandoffsAlone() async {
        let state = AppState()
        let window = UUID()
        let seed = Draft(subject: "parked by a mailto: link")
        state.status = .signedIn
        Self.bumpEveryCommand(on: state, seed: seed, window: window)
        let ticks = Self.ticks(of: state)
        XCTAssertFalse(ticks.contains(0), "precondition: every tick was bumped")
        let disposed = state.lastDisposedEnvelope
        let move = state.pendingMoveRequest

        await state.signOut()

        XCTAssertEqual(Self.ticks(of: state), ticks)
        XCTAssertEqual(state.commandWindow, window)
        XCTAssertEqual(state.lastActiveMainWindow, window)
        XCTAssertEqual(state.pendingComposeSeed, seed)
        XCTAssertEqual(state.pendingFeedCommand, .refresh)
        XCTAssertEqual(state.pendingSidebarTreeCommand, .expandAllFolders)
        XCTAssertNotNil(disposed)
        XCTAssertEqual(state.lastDisposedEnvelope, disposed)
        XCTAssertNotNil(move)
        XCTAssertEqual(state.pendingMoveRequest, move)
    }

    /// The Settings ▸ Account path from the code form: `signOut()` never
    /// touches `mfaError`, so the form's error survives. Unseen today: the
    /// password form does not show it, and `signIn` clears it.
    func testSignOutFromTheCodeFormLeavesItsErrorBehind() async {
        let state = AppState()
        state.status = .mfaCodeRequired(.totp)
        state.mfaError = Self.mismatch

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
        state.signalRemovalFailed(folderPath: "INBOX", uid: 8)
        state.signalDisposed(folderPath: "INBOX", uid: 9)
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
            state.moveRequestTick, state.failedRemovalTick,
        ]
    }

    private static func activity(identifier: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        return activity
    }
}
