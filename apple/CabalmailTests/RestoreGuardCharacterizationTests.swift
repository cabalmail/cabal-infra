import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: the guards at the top of `AppState.restoreIfPossible()`, through
/// the `SessionEnvironment` seam (`SessionHarness`), ahead of workstream 1.3
/// replacing the launch-time restore with a per-account session manager.
///
/// Four guards decide whether a restore runs at all: a wired client, the
/// status (`.signingIn`, `.restoring`, `.signedIn`), the persisted control
/// domain and username, and a token read from the secure store. The last two
/// write `.signedOut` on their way out, so each is pinned from a status that
/// shows the write (an earlier error, the MFA code form) rather than from the
/// `.signedOut` a new `AppState` starts on. The other statuses run a restore
/// in full, the code form included. `RestoreCharacterizationTests` pins the
/// successful paths and `RestoreFailureCharacterizationTests` the catch arms.
/// A quirk that looks wrong is pinned anyway and says so.
@MainActor
final class RestoreGuardCharacterizationTests: XCTestCase {
    private static let domain = "cabalmail.example"
    /// What a password sign-in that meets a second factor asks for.
    private static let challenged = ["loadConfiguration cabalmail.example", "makeSecureStore", "makeClient"]
    /// A restore that wires the session, as the harness smoke run logged it.
    private static let wired = [
        "makeSecureStore",
        "loadConfiguration cabalmail.example",
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

    // MARK: - The persisted pair

    /// Pins current behaviour, which looks like a (minor) defect: with no
    /// persisted pair (a first launch, or one cleared by hand) restore
    /// returns before it builds a secure store, so the keychain is not even
    /// opened, and stored tokens make no difference. On its way out it writes
    /// `.signedOut` over whatever the form showed, so an error the user has
    /// not read yet goes when a compose window's `.task` restores. A reason
    /// already set is left alone.
    /// Tracked in #1826.
    func testWithoutAPersistedPairRestoreWipesAnErrorWithoutOpeningTheStore() async throws {
        try await harness.seedTokens()
        for (domain, username) in [("", ""), ("", "alice"), (Self.domain, "")] {
            let label = "domain '\(domain)', username '\(username)'"
            harness.seedLastSession(controlDomain: domain, username: username)
            harness.appState.sessionManager.status = .error("earlier")
            harness.appState.sessionManager.signedOutReason = .sessionExpired

            await harness.appState.restoreIfPossible()

            XCTAssertEqual(harness.appState.status, .signedOut, label)
            XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired, label)
            XCTAssertEqual(harness.events, [], label)
        }
        XCTAssertTrue(harness.clients.isEmpty)
        XCTAssertTrue(harness.hasStoredTokens, "the guard leaves the keychain alone")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
    }

    /// Pins current behaviour, which looks like a defect: a first-time user
    /// at the code form has no persisted pair yet (only a completed sign-in
    /// writes it), so a restore then (on macOS, reopening the main window or
    /// a mailto: compose window) sends the form back to the password step.
    /// Tracked in #1826.
    func testWithoutAPersistedPairRestoreSendsTheCodeFormBackToThePasswordForm() async throws {
        await harness.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "S1"))
        await harness.appState.signIn(controlDomain: Self.domain, username: "alice", password: "pw")
        XCTAssertEqual(harness.appState.status, .mfaCodeRequired(.totp), "precondition")
        XCTAssertNil(harness.defaults.string(forKey: "cabalmail.lastUsername"), "precondition: no pair yet")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(harness.events, Self.challenged, "the restore made no environment call")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH"])
    }

    // MARK: - The stored tokens

    /// Pins current behaviour, which looks like a (minor) defect: with the
    /// pair but no tokens (a sign-out wipes the tokens and keeps the pair for
    /// the form; so does a refused launch refresh) one secure store is built
    /// and read, and nothing else runs. Like the pair guard it writes
    /// `.signedOut` over an error the form showed (a wrong password after a
    /// sign-out, say) and leaves a reason alone, which is what a compose
    /// window's restore after a refused launch refresh meets.
    /// Tracked in #1826.
    func testWithoutStoredTokensRestoreWipesAnErrorAfterOneStoreRead() async {
        harness.seedLastSession()
        harness.appState.sessionManager.status = .error("earlier")
        harness.appState.sessionManager.signedOutReason = .sessionExpired

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertEqual(harness.events, ["makeSecureStore"], "no configuration load, no client")
        XCTAssertTrue(harness.clients.isEmpty)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
    }

    /// Pins current behaviour, which looks like a defect: a returning user
    /// signing in again after a sign-out is at the code form with the pair
    /// stored and no tokens, so a restore then sends the form back to the
    /// password step. The challenge stays parked: nothing in the UI reaches
    /// it from `.signedOut`, but putting the code form back by hand shows a
    /// code still completes it.
    /// Tracked in #1826.
    func testWithoutStoredTokensRestoreSendsTheCodeFormBackLeavingTheChallengeParked() async throws {
        harness.seedLastSession()
        await harness.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "S1"))
        await harness.appState.signIn(controlDomain: Self.domain, username: "alice", password: "pw")
        XCTAssertEqual(harness.appState.status, .mfaCodeRequired(.totp), "precondition")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.events, Self.challenged + ["makeSecureStore"])
        XCTAssertEqual(harness.clients.count, 1)

        await harness.cognito.script(.mfaAnswer, .tokens(id: "ID-MFA", refresh: "REFRESH"))
        harness.appState.sessionManager.status = .mfaCodeRequired(.totp)
        await harness.appState.submitMfaCode("123456")

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertTrue(harness.appState.client === harness.clients.first, "the parked client is the one wired")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH", "RespondToAuthChallenge"])
    }

    /// The token check is `try?`, so a store that throws on read (a
    /// data-protection keychain that is unavailable on a background launch
    /// reports `.storage("Keychain read failed: ...")`, `.transport` before
    /// #1808) counts as no tokens: `.signedOut` with no reason and no
    /// configuration load, and the tokens it could not read are kept for a
    /// later launch. A read error is not taken for an expiry.
    func testAStoreThatCannotBeReadCountsAsNoTokensAndKeepsThem() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        let makeStore = harness.appState.sessionManager.sessionEnvironment.makeSecureStore
        harness.appState.sessionManager.sessionEnvironment.makeSecureStore = {
            UnreadableSecureStore(base: makeStore())
        }
        harness.appState.sessionManager.status = .error("earlier")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason, "not an expiry")
        XCTAssertEqual(harness.events, ["makeSecureStore"], "no configuration load, no client")
        XCTAssertTrue(harness.clients.isEmpty)
        XCTAssertTrue(harness.hasStoredTokens, "the tokens it could not read are kept")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
    }

    // MARK: - The client and the status

    /// The `client == nil` guard on its own: a status that says `.signedOut`
    /// while the session stays wired passes the status guard, and the client
    /// guard stops it, so no second client is built and wired over the live
    /// one. Nothing puts `.signedIn` back either. The stray submit and
    /// cancel of #1826 used to produce exactly that status; they are now
    /// ignored off the code form, so the test writes it directly.
    func testTheClientGuardStopsARestoreWhileAClientIsWired() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        await harness.appState.restoreIfPossible()
        let client = try XCTUnwrap(harness.appState.client)
        harness.appState.sessionManager.status = .signedOut

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.events, Self.wired, "the second restore made no environment call")
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertTrue(harness.appState.client === client)
        XCTAssertEqual(harness.appState.status, .signedOut)
    }

    /// Only `.signingIn`, `.restoring` and `.signedIn` stop a restore; from
    /// `.error` it runs in full, which is how a second attempt after a failed
    /// one gets anywhere.
    func testRestoreFromTheErrorStatusRunsInFull() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.appState.sessionManager.status = .error("an earlier failure")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.events, Self.wired)
    }

    /// Pins current behaviour, which looks like a (latent) defect: the code
    /// form is not one of the guarded statuses, so a restore while a
    /// password sign-in waits for its second factor wires whatever session
    /// the keychain still holds (one an offline launch kept) over the code
    /// form. The parked challenge's client is abandoned; a code submitted
    /// afterwards meets `.signedIn` and is ignored.
    /// Tracked in #1826.
    func testRestoreFromTheCodeFormWiresTheStoredSessionOverIt() async throws {
        harness.seedLastSession()
        try await harness.seedTokens(id: "KEPT")
        await harness.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "S1"))
        await harness.appState.signIn(controlDomain: Self.domain, username: "alice", password: "pw")
        XCTAssertEqual(harness.appState.status, .mfaCodeRequired(.totp), "precondition")
        let challenged = harness.clients.first

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.events, Self.challenged + Self.wired)
        XCTAssertEqual(harness.clients.count, 2, "restore built its own client")
        XCTAssertTrue(harness.appState.client === harness.clients.last)
        XCTAssertFalse(harness.appState.client === challenged)
        let token = try await harness.appState.client?.authService.currentIdToken()
        XCTAssertEqual(token, "KEPT", "the session wired is the stored one")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH"], "the challenge was never answered")
    }
}

/// A secure store whose reads fail, as a locked keychain's do; writes and
/// removals reach the store it wraps.
private struct UnreadableSecureStore: SecureStore {
    let base: any SecureStore

    func set(_ value: Data, forKey key: String) throws {
        try base.set(value, forKey: key)
    }

    func get(_ key: String) throws -> Data? {
        throw CabalmailError.storage("Keychain read failed: -25308")
    }

    func remove(_ key: String) throws {
        try base.remove(key)
    }
}
