import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: every way `AppState.restoreIfPossible()` fails, through the
/// `SessionEnvironment` seam (`SessionHarness`), ahead of workstream 1.3
/// replacing it with a per-account session manager. Protects:
///
/// - the offline launch (#1779): a configuration load that cannot reach the
///   network stays signed out keeping the tokens, and a refresh that cannot
///   reach Cognito still wires the session;
/// - the refused refresh (#1288): Cognito's `NotAuthorizedException` on
///   REFRESH_TOKEN_AUTH is an expired session, which clears the three
///   keychain keys and sets the reason the sign-in form explains (#1703);
/// - the chain after an offline launch, where the first call's refused
///   refresh reaches the session observer and tears the session down;
/// - the other catch arms: transient errors keep the tokens, any other
///   `CabalmailError` lands on `.error` with its mapped text, and anything
///   else (a corrupt token blob, #1806) on its raw `localizedDescription`.
///
/// `RestoreGuardCharacterizationTests` pins the guards and
/// `RestoreCharacterizationTests` the successful paths;
/// `RestorePipelineCharacterizationTests` pins the Kit half of the chain.
/// The harness hands `AppState` no `Preferences`, so `wireSession`'s
/// preferences branch never runs here. In production its
/// `PreferencesSyncCoordinator` pull is usually the first API call after an
/// offline launch, and so usually the one whose refused refresh tears the
/// session down; it is left out because started, it would race the
/// restore's own Cognito traffic and make the trail nondeterministic. A case
/// that pins behaviour that looks wrong says so.
@MainActor
final class RestoreFailureCharacterizationTests: XCTestCase {
    private static let loaded = ["makeSecureStore", "loadConfiguration cabalmail.example"]
    private static let built = loaded + ["makeClient"]
    private static let wired = built + [
        "requestBadgeAuthorization",
        "requestContactsAccess",
        "sessionDidStart tokens=stored",
        "pushSessionToWatch alice",
    ]
    private static let refresh = "InitiateAuth REFRESH_TOKEN_AUTH"

    private var harness: SessionHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
        harness.seedLastSession()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Configuration load

    /// Offline with no cached config.json (#1779): no client is built and
    /// Cognito is never asked, the tokens stay for a later launch, and there
    /// is no reason on the form.
    func testAConfigLoadThatCannotReachTheNetworkStaysSignedOutKeepingTheTokens() async throws {
        try await harness.seedTokens(expiresIn: -60)
        let blob = try harness.secureStore.get(SecureStoreKey.authTokens)
        harness.configurationResult = .failure(CabalmailError.network("offline"))

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(harness.events, Self.loaded)
        XCTAssertTrue(harness.clients.isEmpty)
        XCTAssertEqual(try harness.secureStore.get(SecureStoreKey.authTokens), blob)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
    }

    /// The rest of the transient arm. Each lands on `.signedOut` with the
    /// tokens kept, and `.signedOut` lets the next restore run in full.
    func testTransientConfigErrorsStaySignedOutKeepingTheTokens() async throws {
        try await harness.seedTokens()
        let errors: [CabalmailError] = [.transport("reset"), .cancelled, .notConfigured]
        for (attempt, error) in errors.enumerated() {
            harness.configurationResult = .failure(error)

            await harness.appState.restoreIfPossible()

            XCTAssertEqual(harness.appState.status, .signedOut, "\(error)")
            XCTAssertNil(harness.appState.signedOutReason, "\(error)")
            XCTAssertTrue(harness.hasStoredTokens, "\(error)")
            XCTAssertEqual(harness.events.count, Self.loaded.count * (attempt + 1), "\(error)")
        }
        XCTAssertTrue(harness.clients.isEmpty)
    }

    /// Any other `CabalmailError` lands on `.error` with `message(for:)`'s
    /// text, keeping the tokens; `.error` lets the next restore run in full.
    /// A Cognito trigger's rejection shows verbatim like maintenance copy, and
    /// a case with no text of its own falls back to its Swift description.
    func testOtherCabalmailErrorsFromTheLoadEndOnTheErrorStatusWithTheirText() async throws {
        try await harness.seedTokens()
        let cases: [(CabalmailError, String)] = [
            (.server(code: "500", message: "boom"), "Server error: boom"),
            (.decoding("not JSON"), "Response error: not JSON"),
            (.protocolError("odd"), "Protocol error: odd"),
            (.maintenance(message: "Back at noon."), "Back at noon."),
            (.server(code: "UserLambdaValidationException", message: "Set up MFA."), "Set up MFA."),
            (.sendInFlight, "sendInFlight"),
        ]
        for (error, text) in cases {
            harness.configurationResult = .failure(error)

            await harness.appState.restoreIfPossible()

            XCTAssertEqual(harness.appState.status, .error(text), "\(error)")
            XCTAssertNil(harness.appState.signedOutReason, "\(error)")
            XCTAssertTrue(harness.hasStoredTokens, "\(error)")
        }
        XCTAssertEqual(harness.events.count, Self.loaded.count * cases.count)
    }

    /// The expiry arm matches on the error alone, not on which step threw
    /// it: the configuration load or the client factory here, validation in
    /// the refresh tests below. Nothing in the chain throws
    /// `.invalidCredentials` on this path since #1288 mapped a refused
    /// refresh to `.authExpired`; it is pinned so the arm's membership shows
    /// if it changes. Thrown before a client exists, it is also the one case
    /// where the arm's own removal of the legacy IMAP keys is what clears
    /// them: building a client's auth service scrubs them first on every
    /// other path.
    func testInvalidCredentialsBeforeAnyClientExistsTakeTheExpiryArm() async throws {
        try await harness.seedTokens()
        try seedImapCredentials()
        harness.configurationResult = .failure(CabalmailError.invalidCredentials)

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertEqual(harness.events, Self.loaded, "no client was built")
        try assertKeychainCleared()

        try await harness.seedTokens()
        try seedImapCredentials()
        harness.appState.signedOutReason = nil
        harness.configurationResult = .success(harness.configuration)
        harness.makeClientFailure = CabalmailError.invalidCredentials

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertEqual(harness.events, Self.loaded + Self.built, "the factory threw before building one")
        XCTAssertTrue(harness.clients.isEmpty)
        try assertKeychainCleared()
    }

    // MARK: - Building the client

    /// `makeClient` throws in production when the cache directory cannot be
    /// made: a non-`CabalmailError` lands on `.error` with its own text, and a
    /// `CabalmailError` follows the same arms as one from the load.
    func testAClientThatCannotBeBuiltEndsOnItsErrorKeepingTheTokens() async throws {
        try await harness.seedTokens()
        harness.makeClientFailure = NSError(
            domain: "RestoreFailureCharacterizationTests", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "No cache directory."]
        )

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .error("No cache directory."))
        XCTAssertEqual(harness.events, Self.built)
        XCTAssertTrue(harness.clients.isEmpty)
        XCTAssertTrue(harness.hasStoredTokens)

        harness.makeClientFailure = CabalmailError.transport("disk")
        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertTrue(harness.hasStoredTokens)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
    }

    // MARK: - Refresh

    /// #1779: a refresh that never reaches Cognito says nothing about the
    /// session, so the expired tokens are wired as they are and cached mail
    /// stays readable. Nothing is announced and nothing is written back.
    func testAnUnreachableCognitoStillWiresTheSession() async throws {
        try await harness.seedTokens(id: "ID-1", expiresIn: -60)
        let blob = try harness.secureStore.get(SecureStoreKey.authTokens)
        await harness.cognito.script(.refresh, .unreachable)
        let announcements = harness.appState.sessionInvalidation.events()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(harness.events, Self.wired)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [Self.refresh])
        XCTAssertEqual(try harness.secureStore.get(SecureStoreKey.authTokens), blob, "the expired pair stays")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    /// #1288: a refusal is an expired session. All three keychain keys go
    /// (the IMAP pair already went when the client's auth service was
    /// built), the pair stays so the form pre-fills, and the reason is set. The
    /// client that was built is dropped without a hook: the watch is not
    /// told, and no observer exists yet, so the Kit's announcement (#1703)
    /// reaches only a listener the test subscribed; the monitor keeps no
    /// replay for one that subscribes later.
    func testARefusedRefreshClearsTheKeychainAndSignsOutWithAReason() async throws {
        try await harness.seedTokens(expiresIn: -60)
        try seedImapCredentials()
        await harness.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "revoked"))
        let announcements = harness.appState.sessionInvalidation.events()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        try assertKeychainCleared()
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.controlDomain"), "cabalmail.example")
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.lastUsername"), "alice")
        XCTAssertEqual(harness.events, Self.built, "no session hook runs")
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertNil(harness.appState.client)
        XCTAssertNil(harness.appState.sessionExpiryTask, "nothing in AppState was listening")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [Self.refresh])
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1, "the Kit announced the expiry")
        let late = await bufferedCount(harness.appState.sessionInvalidation.events())
        XCTAssertEqual(late, 0, "and nothing replays it")
    }

    /// An expired token with no refresh token behind it is the same expiry,
    /// decided without asking Cognito, and announced the same way.
    func testAnExpiredTokenWithNoRefreshTokenTakesTheExpiryArmWithoutCognito() async throws {
        try await harness.seedTokens(expiresIn: -60, refresh: nil)
        try seedImapCredentials()
        let announcements = harness.appState.sessionInvalidation.events()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        try assertKeychainCleared()
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [])
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1)
    }

    /// Tokens that vanish while the configuration loads (something outside
    /// `AppState` removed them: its own `signOut()` cannot, with no client
    /// wired yet) surface as `.notSignedIn`, which the expiry arm also takes:
    /// the form explains an expiry, though nothing announced one.
    func testTokensThatVanishMidRestoreTakeTheExpiryArmWithoutAnAnnouncement() async throws {
        try await harness.seedTokens()
        let announcements = harness.appState.sessionInvalidation.events()
        harness.holdNextConfigurationLoad()
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        await harness.awaitConfigurationLoad()

        try harness.secureStore.remove(SecureStoreKey.authTokens)
        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        XCTAssertEqual(harness.events, Self.built)
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    /// Pins current behaviour, which looks like a defect: any refusal other
    /// than `NotAuthorizedException` (a throttle, Cognito's own outage) is
    /// neither unreachable nor an expiry, so a launch whose session is still
    /// good, and whose cached mail would be readable, lands on the error form
    /// instead of the offline launch. The tokens stay, so the next launch
    /// tries again.
    /// Tracked in #1828.
    func testAnotherCognitoRefusalEndsOnTheErrorStatusKeepingTheTokens() async throws {
        try await harness.seedTokens(expiresIn: -60)
        await harness.cognito.script(.refresh, .error(type: "TooManyRequestsException", message: "Rate exceeded"))

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .error("Server error: Rate exceeded"))
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertTrue(harness.hasStoredTokens)
        XCTAssertNil(harness.appState.client)
        XCTAssertEqual(harness.events, Self.built)
    }

    /// The offline launch's other half (#1779, #1703): restored offline on
    /// an expired token, the session's first call refreshes before it is
    /// sent. Cognito refusing it announces the expiry, and the observer the
    /// restore started tears the session down with the reason, running the
    /// sign-out hooks while the dead tokens are still stored.
    func testAnOfflineLaunchWhoseRefreshIsRefusedLaterTearsTheSessionDown() async throws {
        try await harness.seedTokens(expiresIn: -60)
        await harness.cognito.script(.refresh, .unreachable)
        await harness.appState.restoreIfPossible()
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: the offline launch wired the session")
        let client = try XCTUnwrap(harness.appState.client)
        await harness.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "revoked"))

        do {
            _ = try await client.apiClient.listAddresses()
            XCTFail("expected the refused refresh to throw")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired, "the call site still gets its throw")
        }
        try await waitUntilOnMainActor {
            harness.appState.status == .signedOut && harness.appState.signedOutReason == .sessionExpired
        }

        XCTAssertNil(harness.appState.client)
        XCTAssertNil(harness.appState.sessionExpiryTask)
        XCTAssertFalse(harness.hasStoredTokens)
        XCTAssertEqual(harness.events, Self.wired + ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [Self.refresh, Self.refresh], "the API request itself is never sent")
    }

    // MARK: - Not a CabalmailError

    /// Pins current behaviour, which looks like a defect: a token blob that
    /// no longer decodes passes restore's presence check, then surfaces on
    /// the error form as the raw decoding error. The blob is kept, so every
    /// launch after it (a new `AppState` over the same keychain) lands on
    /// the same text until the user signs in again.
    /// Tracked in #1806.
    func testACorruptTokenBlobEndsOnTheRawDecodingErrorEveryLaunch() async throws {
        let blob = Data("not a token pair".utf8)
        try harness.secureStore.set(blob, forKey: SecureStoreKey.authTokens)
        let expected = decodingErrorText(blob)

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .error(expected))
        XCTAssertNil(harness.appState.signedOutReason)
        XCTAssertEqual(harness.events, Self.built)
        XCTAssertEqual(try harness.secureStore.get(SecureStoreKey.authTokens), blob)
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, [], "it fails reading the keychain, before any refresh")

        let relaunched = AppState()
        relaunched.sessionEnvironment = harness.appState.sessionEnvironment
        await relaunched.restoreIfPossible()

        XCTAssertEqual(relaunched.status, .error(expected))
        XCTAssertEqual(harness.events, Self.built + Self.built)
        XCTAssertEqual(try harness.secureStore.get(SecureStoreKey.authTokens), blob)
    }

    // MARK: - Helpers

    private func decodingErrorText(_ blob: Data) -> String {
        do {
            _ = try JSONDecoder().decode(AuthTokens.self, from: blob)
            return "decoded"
        } catch {
            return error.localizedDescription
        }
    }

    private func seedImapCredentials() throws {
        try harness.secureStore.setString("alice", forKey: SecureStoreKey.imapUsername)
        try harness.secureStore.setString("secret", forKey: SecureStoreKey.imapPassword)
    }

    private func assertKeychainCleared(file: StaticString = #filePath, line: UInt = #line) throws {
        for key in [SecureStoreKey.authTokens, SecureStoreKey.imapUsername, SecureStoreKey.imapPassword] {
            XCTAssertNil(try harness.secureStore.get(key), "\(key) was left behind", file: file, line: line)
        }
    }
}
