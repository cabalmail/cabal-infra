import XCTest
import Observation
import CabalmailKit
@testable import CabalmailUI

/// Workstream 0.8 characterization suite: what `AppState.wireSession` builds
/// and starts once a sign-in has tokens, what `refreshWatchSession()` hands
/// the watch, and what a second sign-in after a sign-out builds afresh. The
/// rearchitecture (workstream 1.3) moves all of this into a per-account
/// session manager; these record it as it is today, through the
/// `SessionEnvironment` seam (`SessionHarness`), so the move shows any change.
///
/// Protects the #1703 contract that the session observer is listening by the
/// time the app reads as signed in (a signal in the gap was dropped and the
/// app stayed signed in), and the watch hand-off that the watch's "open
/// Cabalmail on your iPhone" instruction relies on. The teardown half is
/// `SignOutCharacterizationTests`.
@MainActor
final class SessionWiringCharacterizationTests: XCTestCase {
    /// What a sign-in asks of the environment before `wireSession` flips the
    /// status, and what it asks after.
    private static let beforeSignedIn = [
        "loadConfiguration cabalmail.example", "makeSecureStore", "makeClient",
        "publishControlDomain cabalmail.example",
    ]
    private static let afterSignedIn = [
        "requestBadgeAuthorization", "requestContactsAccess", "sessionDidStart tokens=stored",
        "pushSessionToWatch alice",
    ]
    private static let teardown = ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"]

    private var harness: SessionHarness!

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    // MARK: - What wireSession builds, and in what order

    /// The client, the saved-counts cache, the navigation cursor and the
    /// session observer are all in place at the moment `status` is written
    /// `.signedIn`, and none of the session hooks has run yet: badge
    /// authorization, the contacts prompt, `sessionDidStart` and the watch
    /// push all come after the flip, in that order.
    func testSignInWiresTheSessionBeforeTheStatusFlipsToSignedIn() async throws {
        let probe = WiringProbe(watching: harness)

        await SignOutSuiteSteps.signIn(harness)

        XCTAssertEqual(probe.writes.map(\.leaving), [.signedOut, .signingIn], "two writes: signing in, signed in")
        let atSigningIn = try XCTUnwrap(probe.writes.first)
        XCTAssertFalse(atSigningIn.clientWired)
        XCTAssertEqual(atSigningIn.events, [])
        let atSignedIn = try XCTUnwrap(probe.writes.last)
        XCTAssertTrue(atSignedIn.clientWired)
        XCTAssertTrue(atSignedIn.countsOnClientCache, "savedFolderCounts points at the client's folder state")
        XCTAssertTrue(atSignedIn.navWired)
        XCTAssertTrue(atSignedIn.observing, "the observer is subscribed before .signedIn (#1703)")
        XCTAssertEqual(atSignedIn.events, Self.beforeSignedIn)
        XCTAssertEqual(harness.events, Self.beforeSignedIn + Self.afterSignedIn)
    }

    /// The strongest form of the #1703 ordering: a signal sent from inside the
    /// `.signedIn` write itself is not lost. The observer subscribed
    /// synchronously before the write, so the signal is buffered and the
    /// session comes down once the main actor is free. Only the end state is
    /// pinned: the teardown runs at `wireSession`'s first suspension (the
    /// watch push), so where the watch push lands in the event log is a race.
    func testAnExpiryAnnouncedAsTheStatusFlipsToSignedInStillTearsTheSessionDown() async throws {
        let probe = WiringProbe(watching: harness, announceExpiryOnSignedIn: true)

        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-1"))
        await harness.appState.signIn(controlDomain: "cabalmail.example", username: "alice", password: "hunter2")
        let observer = try XCTUnwrap(probe.observerAtSignedIn, "no observer existed as the status flipped")
        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertNil(harness.appState.client)
        XCTAssertEqual(harness.events.filter { $0.hasPrefix("sessionWillEnd") }, ["sessionWillEnd tokens=stored"])
        XCTAssertEqual(harness.events.filter { $0.hasPrefix("sessionDidEnd") }, ["sessionDidEnd tokens=gone"])
    }

    /// The plain form: an announcement the moment `signIn` returns, with no
    /// suspension in between, tears the session down through `signOut()`.
    func testAnAnnouncementTheMomentSignInReturnsTearsTheSessionDown() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let observer = try XCTUnwrap(harness.appState.sessionExpiryTask)
        harness.appState.sessionInvalidation.sessionDidExpire()

        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertNil(harness.appState.client)
        XCTAssertNil(harness.appState.sessionExpiryTask)
        XCTAssertEqual(harness.events, Self.beforeSignedIn + Self.afterSignedIn + Self.teardown)
    }

    /// The cursor comes from the environment's factory (the harness's client
    /// ID and defaults), over the session's client, and the saved-counts
    /// writer points at that client's folder state. The harness's client keeps
    /// its folder state memory-only, which saves nothing, so the write-through
    /// itself is not observable here.
    func testTheCursorComesFromTheEnvironmentAndCountsPointAtTheClient() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let client = try XCTUnwrap(state.client)
        let coordinator = try XCTUnwrap(state.navCoordinator)

        XCTAssertTrue(coordinator.client === client)
        XCTAssertEqual(coordinator.clientID, "session-harness")
        coordinator.recordFolder("Archive")
        coordinator.flushSession()
        XCTAssertEqual(ResumeSessionStore(defaults: harness.defaults).loadSession()?.folder, "Archive")
        XCTAssertTrue(state.mailStore.counts.savedFolderCounts.cache === client.folderStateCache)
    }

    /// The badge poller's first tick runs at once: one STATUS on INBOX, whose
    /// UNSEEN becomes `inboxUnreadCount`. It feeds the badge only, not the
    /// sidebar's counts. The feed poller is running too (its pass is a no-op
    /// without an RSS store).
    func testTheBadgePollerTicksAtOnceAndTheFeedPollerRuns() async throws {
        await harness.imap.scriptStatusResults([.success(FolderStatus(messages: 40, unseen: 7))])

        await SignOutSuiteSteps.signIn(harness)
        try await waitUntilOnMainActor { self.harness.appState.mailStore.counts.inboxUnreadCount == 7 }

        let calls = await harness.imap.statusCalls
        XCTAssertEqual(calls.map(\.path), ["INBOX"], "one tick; the next is a minute away")
        XCTAssertEqual(calls.map(\.flagged), [false])
        XCTAssertNil(
            harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], "the badge poll does not feed the sidebar"
        )
        let feedPoll = try XCTUnwrap(harness.appState.feedRefreshTask)
        XCTAssertFalse(feedPoll.isCancelled)
    }

    /// A Spotlight tap parked before any session is replayed by
    /// `wireSession` into the new session's cursor. No envelope is cached
    /// for it, so the request carries no Message-ID.
    func testASpotlightTapParkedBeforeSignInIsRoutedIntoTheNewSession() async throws {
        let ref = SpotlightMessageRef(folder: "Archive/2026", uid: 4242)
        harness.appState.routeSpotlightRef(ref)
        XCTAssertEqual(harness.appState.pendingSpotlightRef, ref, "precondition: parked")

        await SignOutSuiteSteps.signIn(harness)

        XCTAssertNil(harness.appState.pendingSpotlightRef)
        let coordinator = try XCTUnwrap(harness.appState.navCoordinator)
        try await waitUntilOnMainActor { coordinator.navigateRequest != nil }
        let request = try XCTUnwrap(coordinator.navigateRequest)
        XCTAssertEqual(request.folder, "Archive/2026")
        XCTAssertEqual(request.uid, 4242)
        XCTAssertNil(request.messageID)
        XCTAssertEqual(request.clientID, "session-harness")
    }

    /// With the app's `Preferences` handed in, wiring activates them for the
    /// signed-in account and starts a sync coordinator, whose start pulls the
    /// server copy and then watches local edits. `usePreferences` itself
    /// publishes the control domain even when none is stored yet.
    func testWiringActivatesTheAccountsPreferencesAndStartsTheirSync() async throws {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        harness.appState.usePreferences(preferences)
        XCTAssertNil(preferences.accountScope, "no last session to pre-activate")
        XCTAssertEqual(harness.events, ["publishControlDomain "])

        await SignOutSuiteSteps.signIn(harness)

        XCTAssertNotNil(preferences.accountScope)
        XCTAssertNotNil(harness.appState.prefsCoordinator)
        try await waitUntilOnMainActor { preferences.onLocalChange != nil }
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH", "API GET /prod/get_preferences"])
    }

    // MARK: - refreshWatchSession

    /// Each call pushes the tokens stored now (a silent refresh since the
    /// sign-in is picked up) with the configuration, for `lastUsername` as it
    /// reads at the time of the call rather than the username the session
    /// was wired with. Today the two only differ if the stored value changes
    /// under a running session.
    func testRefreshingTheWatchSessionPushesTheCurrentTokensForTheLastUsername() async throws {
        let log = captureWatchPushes()
        await SignOutSuiteSteps.signIn(harness)
        XCTAssertEqual(log.pushes, [WatchPush(domain: "cabalmail.example", idToken: "ID-1", username: "alice")])

        try await harness.seedTokens(id: "ID-2")
        await harness.appState.refreshWatchSession()
        harness.appState.lastUsername = "bob"
        await harness.appState.refreshWatchSession()

        XCTAssertEqual(log.pushes.dropFirst(), [
            WatchPush(domain: "cabalmail.example", idToken: "ID-2", username: "alice"),
            WatchPush(domain: "cabalmail.example", idToken: "ID-2", username: "bob"),
        ])
    }

    /// Stored credentials are not a session: before a sign-in or restore has
    /// wired a client, and again after a sign-out, the call does nothing even
    /// with tokens in the store (re-seeded after the sign-out wiped them, so
    /// both halves turn on the missing client, not the missing tokens).
    func testRefreshingTheWatchSessionWithNoSessionDoesNothing() async throws {
        let log = captureWatchPushes()
        harness.seedLastSession()
        try await harness.seedTokens()

        await harness.appState.refreshWatchSession()
        XCTAssertEqual(log.pushes, [])
        XCTAssertEqual(harness.events, [])

        await SignOutSuiteSteps.signIn(harness)
        await harness.appState.signOut()
        try await harness.seedTokens(id: "ID-2")
        XCTAssertTrue(harness.hasStoredTokens, "precondition")
        let afterSignOut = harness.events
        await harness.appState.refreshWatchSession()

        XCTAssertEqual(log.pushes.count, 1, "only the sign-in's own push")
        XCTAssertEqual(harness.events, afterSignOut)
    }

    /// With the session wired but its tokens gone from the store, the push is
    /// skipped and the session is left as it is.
    func testRefreshingTheWatchSessionWithTheTokensGoneSkipsThePush() async throws {
        let log = captureWatchPushes()
        await SignOutSuiteSteps.signIn(harness)
        try harness.secureStore.remove(SecureStoreKey.authTokens)

        await harness.appState.refreshWatchSession()

        XCTAssertEqual(log.pushes.count, 1, "only the sign-in's own push")
        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertNotNil(harness.appState.client)
    }

    // MARK: - Signing in again after a sign-out

    /// The second sign-in builds its own client, cursor and observer and asks
    /// the environment for exactly what the first did. The first observer
    /// ended at the sign-out, so a later signal reaches only the second, and
    /// the session comes down once.
    func testSigningInAgainBuildsAFreshClientCursorAndObserver() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let firstClient = try XCTUnwrap(state.client)
        let firstCursor = try XCTUnwrap(state.navCoordinator)
        let firstObserver = try XCTUnwrap(state.sessionExpiryTask)
        let firstEvents = harness.events
        await state.signOut()
        await SignOutSuiteSteps.awaitEnd(of: firstObserver, in: self)
        let mark = harness.events.count

        await SignOutSuiteSteps.signIn(harness)

        XCTAssertEqual(harness.clients.count, 2)
        XCTAssertTrue(state.client === harness.clients.last)
        XCTAssertFalse(state.client === firstClient, "the old client is not reused")
        XCTAssertFalse(state.navCoordinator === firstCursor)
        let secondObserver = try XCTUnwrap(state.sessionExpiryTask)
        XCTAssertNotEqual(secondObserver, firstObserver)
        XCTAssertEqual(Array(harness.events[mark...]), firstEvents)

        state.sessionInvalidation.sessionDidExpire()
        await SignOutSuiteSteps.awaitEnd(of: secondObserver, in: self)

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertEqual(harness.events.filter { $0.hasPrefix("sessionWillEnd") }.count, 2, "one per session")
    }

    /// The badge poller is restartable: sign-out drops its task, so the next
    /// session's poller starts and ticks at once.
    func testASignInAfterSignOutStartsAFreshBadgePoller() async throws {
        await harness.imap.scriptStatusResults([
            .success(FolderStatus(messages: 40, unseen: 7)),
            .success(FolderStatus(messages: 41, unseen: 2)),
        ])
        await SignOutSuiteSteps.signIn(harness)
        try await waitUntilOnMainActor { self.harness.appState.mailStore.counts.inboxUnreadCount == 7 }
        await harness.appState.signOut()
        XCTAssertEqual(harness.appState.mailStore.counts.inboxUnreadCount, 0)

        await SignOutSuiteSteps.signIn(harness)
        try await waitUntilOnMainActor { self.harness.appState.mailStore.counts.inboxUnreadCount == 2 }

        let calls = await harness.imap.statusCalls
        XCTAssertEqual(calls.map(\.path), ["INBOX", "INBOX"])
        XCTAssertEqual(harness.events.filter { $0 == "requestBadgeAuthorization" }.count, 2)
    }

    // MARK: - Helpers

    /// Wraps the harness's watch hook to keep what each push carried.
    private func captureWatchPushes() -> WatchPushLog {
        let log = WatchPushLog()
        let original = harness.appState.sessionEnvironment.hooks.pushSessionToWatch
        harness.appState.sessionEnvironment.hooks.pushSessionToWatch = { configuration, tokens, username in
            log.pushes.append(WatchPush(
                domain: configuration.controlDomain, idToken: tokens.idToken, username: username
            ))
            original(configuration, tokens, username)
        }
        return log
    }
}

private struct WatchPush: Equatable {
    let domain: String
    let idToken: String
    let username: String
}

@MainActor
private final class WatchPushLog {
    var pushes: [WatchPush] = []
}

/// Snapshots the session wiring at every `status` write, from inside the
/// write: Observation calls `onChange` before the new value is stored, so
/// `leaving` is the status being replaced. Optionally announces an expiry
/// from inside the `.signedIn` write.
@MainActor
private final class WiringProbe {
    struct Write {
        let leaving: AppState.Status
        let clientWired: Bool
        let countsOnClientCache: Bool
        let navWired: Bool
        let observing: Bool
        let events: [String]
    }

    private(set) var writes: [Write] = []
    private(set) var observerAtSignedIn: Task<Void, Never>?
    private let harness: SessionHarness
    private let announceExpiryOnSignedIn: Bool

    init(watching harness: SessionHarness, announceExpiryOnSignedIn: Bool = false) {
        self.harness = harness
        self.announceExpiryOnSignedIn = announceExpiryOnSignedIn
        arm()
    }

    private func arm() {
        withObservationTracking {
            _ = harness.appState.status
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.record()
                self?.arm()
            }
        }
    }

    private func record() {
        let state = harness.appState
        let client = state.client
        writes.append(Write(
            leaving: state.status,
            clientWired: client != nil,
            countsOnClientCache: client.map {
                state.mailStore.counts.savedFolderCounts.cache === $0.folderStateCache
            } ?? false,
            navWired: state.navCoordinator != nil,
            observing: state.sessionExpiryTask != nil,
            events: harness.events
        ))
        guard state.status == .signingIn else { return }
        observerAtSignedIn = state.sessionExpiryTask
        if announceExpiryOnSignedIn { state.sessionInvalidation.sessionDidExpire() }
    }
}
