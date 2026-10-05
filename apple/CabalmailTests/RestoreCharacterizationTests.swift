import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: `AppState.restoreIfPossible()`, the launch-time restore, end to
/// end through the `SessionEnvironment` seam (`SessionHarness`), ahead of
/// workstream 1.3 replacing it with a per-account session manager. This file
/// pins the two successful paths (a fresh token, an expired one Cognito
/// refreshes), that a restore runs once, and what happens when other session
/// calls land while a restore is in flight. `RestoreGuardCharacterizationTests`
/// pins the guards that decide whether a restore runs at all, and
/// `RestoreFailureCharacterizationTests` every catch arm, the offline launch
/// (#1779) and the refused refresh (#1288, #1703).
///
/// The Kit half of the chain (config fetch, `make()`, `OfflineLaunch`) is
/// pinned by `RestorePipelineCharacterizationTests`; these pin what AppState
/// does around it: which environment calls and hooks run, in what order, the
/// status it passes through and lands on, and what it leaves in the keychain.
/// The harness hands `AppState` no `Preferences`, so `wireSession`'s
/// preferences branch (the account-scope activation and the
/// `PreferencesSyncCoordinator` pull) never runs here: started, its pull
/// would race the restore's own Cognito traffic and make the trail
/// nondeterministic. A quirk that looks wrong is pinned anyway and says so.
@MainActor
final class RestoreCharacterizationTests: XCTestCase {
    private static let domain = "cabalmail.example"
    private static let loaded = ["makeSecureStore", "loadConfiguration cabalmail.example"]
    /// A restore that wires the session, as the harness smoke run logged it.
    /// No `publishControlDomain`: restore reads the persisted pair and never
    /// writes it back.
    private static let wired = loaded + [
        "makeClient",
        "requestBadgeAuthorization",
        "requestContactsAccess",
        "sessionDidStart tokens=stored",
        "pushSessionToWatch alice",
    ]

    private var harness: SessionHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Fresh token

    /// `.restoring` is set before the first suspension, so the splash is up
    /// while the configuration loads; the stored, unexpired ID token is then
    /// taken as is, with no Cognito round trip.
    func testAFreshTokenRestoresThroughTheRestoringStatusWithoutAskingCognito() async throws {
        harness.seedLastSession()
        try await harness.seedTokens(id: "ID-1")
        let before = try storedTokens()

        let restore = await startHeldRestore()

        XCTAssertEqual(harness.appState.status, .restoring)
        XCTAssertEqual(harness.events, Self.loaded)
        XCTAssertNil(harness.appState.client, "no client until the load returns")

        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.events, Self.wired)
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertTrue(harness.appState.client === harness.clients.first)
        XCTAssertNotNil(harness.appState.navCoordinator)
        XCTAssertNotNil(harness.appState.sessionExpiryTask, "the session observer starts with the session")
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(try storedTokens(), before, "the stored pair is untouched")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [], "no Cognito call for a fresh token")
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.controlDomain"), Self.domain)
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.lastUsername"), "alice")
    }

    /// Restore reads whatever domain the last session left, and the hooks
    /// get the persisted username, not anything from the configuration.
    func testRestoreLoadsThePersistedDomainAndHandsTheWatchThePersistedUsername() async throws {
        harness.seedLastSession(controlDomain: "mail.example.net", username: "bob")
        try await harness.seedTokens()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        let load = harness.events.first { $0.hasPrefix("loadConfiguration") }
        XCTAssertEqual(load, "loadConfiguration mail.example.net")
        XCTAssertEqual(harness.events.last, "pushSessionToWatch bob")
        XCTAssertFalse(harness.events.contains { $0.hasPrefix("publishControlDomain") })
    }

    // MARK: - Expired token

    /// One REFRESH_TOKEN_AUTH; Cognito's answer carries no refresh token, so
    /// the stored pair keeps the old one beside the new ID token. The
    /// refresh announces nothing.
    func testAnExpiredTokenRefreshesOnceAndStoresTheNewPair() async throws {
        harness.seedLastSession()
        try await harness.seedTokens(id: "ID-1", expiresIn: -60)
        await harness.cognito.script(.refresh, .tokens(id: "ID-2", refresh: nil))
        let announcements = harness.appState.sessionInvalidation.events()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.events, Self.wired)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth REFRESH_TOKEN_AUTH"])
        let stored = try XCTUnwrap(storedTokens())
        XCTAssertEqual(stored.idToken, "ID-2")
        XCTAssertEqual(stored.refreshToken, "REFRESH")
        XCTAssertFalse(stored.isExpired())
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0, "a refresh that works is not an expiry")
    }

    // MARK: - Idempotence

    /// The app entry's `.task` and a compose scene's both call restore at
    /// launch. The second lands on `.restoring` and returns at once: one
    /// configuration load, one client.
    func testASecondRestoreWhileTheFirstIsHeldIsANoOp() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let first = await startHeldRestore()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .restoring)
        XCTAssertEqual(harness.events, Self.loaded, "the second restore made no environment call")

        harness.releaseConfigurationLoad()
        await first.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.events, Self.wired)
        XCTAssertEqual(harness.clients.count, 1)
    }

    /// A scene that appears after the session is wired cannot rebuild it.
    /// Both the `client == nil` guard and the status guard stop it here;
    /// `RestoreGuardCharacterizationTests` pins the client guard on its own.
    func testRestoreAfterASuccessfulRestoreIsANoOp() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        await harness.appState.restoreIfPossible()
        let client = harness.appState.client

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.events, Self.wired)
        XCTAssertTrue(harness.appState.client === client)
        XCTAssertEqual(harness.clients.count, 1)
    }

    // MARK: - Session calls that land mid-restore

    /// A sign-out while the configuration loads waits for the restore, which
    /// then ends the session it built rather than wire it: the sign-out
    /// hooks run while the tokens are still stored, the tokens go, and the
    /// sign-in form shows with no reason (#1827). It used to find no client,
    /// flip the status and leave the tokens stored, and the restore then
    /// wired the session over it: a sign-out that did not sign out.
    /// Reachable on macOS: the Settings window (Cmd-,) is its own scene,
    /// which `ContentView`'s status switch never gates; it opens on Account,
    /// whose Sign Out button is unconditional; and a slow network keeps the
    /// splash up, since `ConfigLoader` tries the network before its cached
    /// copy.
    func testASignOutWhileRestoringEndsTheSessionTheRestoreBuilt() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let restore = await startHeldRestore()

        let signOut = try await startSignOut()
        XCTAssertEqual(harness.appState.status, .restoring, "the sign-out waits for the restore")

        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertNil(harness.appState.client)
        XCTAssertNil(harness.appState.navCoordinator)
        XCTAssertNil(harness.appState.sessionExpiryTask, "nothing observes a session that never started")
        XCTAssertEqual(harness.events, Self.loaded + [
            "makeClient", "sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone",
        ])
        XCTAssertFalse(harness.hasStoredTokens)
    }

    /// Signing back in after that sign-out waits for the restore to end, so
    /// the restore's teardown of the session it built cannot remove the
    /// tokens the sign-in stores: the stored tokens are one keychain item
    /// (#1827).
    func testASignInAfterASignOutWhileRestoringWaitsForTheRestoreToEnd() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let restore = await startHeldRestore()
        let signOut = try await startSignOut()
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-2"))
        let appState = harness.appState
        let signIn = Task {
            await appState.signIn(controlDomain: Self.domain, username: "alice", password: SignInScript.password)
        }
        // Let the sign-in get as far as it can while the restore is held.
        for _ in 0..<20 { await Task.yield() }

        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value
        await signIn.value

        XCTAssertEqual(harness.events, Self.loaded + [
            "makeClient", "sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone",
        ] + SignInScript.clientBuilt + SignInScript.wired("alice"))
        XCTAssertEqual(harness.appState.status, .signedIn)
        let tokens = await harness.appState.client?.authService.currentTokens()
        XCTAssertEqual(tokens?.idToken, "ID-2")
        XCTAssertTrue(harness.hasStoredTokens)
    }

    /// When the restore that a sign-out waits for fails before it has a
    /// client (here, no configuration offline), the stored tokens still go:
    /// the transient arm would have kept them for a later launch, but the
    /// user asked to sign out (#1827).
    func testASignOutWhileARestoreFailsRemovesTheStoredTokens() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.configurationResult = .failure(CabalmailError.network("offline"))
        let restore = await startHeldRestore()

        let signOut = try await startSignOut()
        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(harness.events, Self.loaded, "no client, so no session hooks")
        XCTAssertFalse(harness.hasStoredTokens)
    }

    /// An expiry handled mid-restore is ignored: no session is live yet, and
    /// the restore answers for its own refused refresh. It used to sign out
    /// with a reason, and the restore then wired the session anyway under
    /// that stale reason (#1826). No observer is subscribed during a restore
    /// (`sessionExpiryTask` lives from `wireSession` to `signOut`), so only a
    /// direct call gets here.
    func testAnExpiryWhileRestoringIsIgnored() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let restore = await startHeldRestore()

        await harness.appState.handleSessionExpiry()
        XCTAssertEqual(harness.appState.status, .restoring)

        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertNil(harness.appState.signedOutReason)
    }

    /// Restore never clears `signedOutReason` (only `signIn` and `signOut`
    /// do), so one left from earlier survives a successful restore. Benign:
    /// the reason shows only on the sign-in form, and every way back to the
    /// form from `.signedIn` goes through `signOut()`, which clears it first.
    func testASuccessfulRestoreLeavesAnEarlierReasonInPlace() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.appState.signedOutReason = .sessionExpired

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
    }

    // MARK: - Helpers

    /// Starts a sign-out and returns once it has been recorded, i.e. with its
    /// teardown waiting.
    private func startSignOut() async throws -> Task<Void, Never> {
        let appState = harness.appState
        let signOut = Task { await appState.signOut() }
        try await waitUntilOnMainActor { appState.teardownGate.isTearingDown }
        return signOut
    }

    /// Starts a restore whose configuration load parks, and returns once the
    /// load has arrived, i.e. with the restore suspended inside it.
    private func startHeldRestore() async -> Task<Void, Never> {
        harness.holdNextConfigurationLoad()
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        await harness.awaitConfigurationLoad()
        return restore
    }

    private func storedTokens() throws -> AuthTokens? {
        guard let data = try harness.secureStore.get(SecureStoreKey.authTokens) else { return nil }
        return try JSONDecoder().decode(AuthTokens.self, from: data)
    }
}
