import XCTest
import CabalmailKit
@testable import Cabalmail

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

    /// Pins current behaviour, which looks like a defect: restore has no
    /// cancellation. A sign-out while the configuration loads finds no
    /// client, so it only flips the status and leaves the tokens stored, and
    /// the restore then wires the session it was building over the
    /// signed-out state: a sign-out that does not sign out. Reachable on
    /// macOS: the Settings window (Cmd-,) is its own scene, which
    /// `ContentView`'s status switch never gates; it opens on Account, whose
    /// Sign Out button is unconditional; and a slow network keeps the splash
    /// up, since `ConfigLoader` tries the network before its cached copy.
    /// Tracked in #1827.
    func testASignOutWhileRestoringIsOverriddenWhenTheRestoreLands() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let restore = await startHeldRestore()

        await harness.appState.signOut()
        XCTAssertEqual(harness.appState.status, .signedOut, "precondition")

        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertNotNil(harness.appState.client)
        XCTAssertEqual(harness.events, Self.wired, "the sign-out ran no hook: there was no client")
        XCTAssertTrue(harness.hasStoredTokens)
    }

    /// Pins current behaviour, which looks like a (latent) defect: an expiry
    /// handled mid-restore signs out with a reason, then the restore wires
    /// the session anyway and leaves the stale reason set under `.signedIn`.
    /// No observer is subscribed during a restore (`sessionExpiryTask` lives
    /// from `wireSession` to `signOut`), so only a direct call gets here.
    /// `SessionLifecycleCharacterizationTests`'
    /// `testAnExpiryWhileRestoringSignsOutWithAReason` pins the expiry's own
    /// effect, which is consistent; this pins the restore in flight
    /// overriding it.
    /// Tracked in #1826.
    func testAnExpiryWhileRestoringIsOverriddenAndItsReasonOutlivesIt() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let restore = await startHeldRestore()

        await harness.appState.handleSessionExpiry()
        XCTAssertEqual(harness.appState.status, .signedOut, "precondition")

        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
    }

    /// Restore never clears `signedOutReason` (only `signIn` and `signOut`
    /// do), so one left from earlier survives a successful restore. Benign
    /// today, unlike the expiry mid-restore above, where the restore undoes
    /// the sign-out the reason explains: the reason shows only on the sign-in
    /// form, and every way back to the form from `.signedIn`, except the
    /// stray submit or cancel of #1826, goes through `signOut()`, which
    /// clears it first.
    func testASuccessfulRestoreLeavesAnEarlierReasonInPlace() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.appState.signedOutReason = .sessionExpired

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
    }

    // MARK: - Helpers

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
