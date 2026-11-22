import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: `AppState.signIn`, driven end
/// to end through `SessionHarness`. Workstream 1.3 replaces AppState's
/// sign-in, restore and sign-out with a per-account session manager; these
/// pin what a password sign-in does today, quirks included, so that move
/// shows any change:
///
/// - the status walk (`.signingIn` while config.json loads, then
///   `.signedIn`) and the prologue that clears the code form's error and the
///   sign-in form's explanation (#1703's `signedOutReason`);
/// - what a success builds, wires and records, in order, and what it
///   remembers: the last-session defaults and the tokens a later launch
///   restores from. The config.json cache an offline launch also needs
///   (#1779) is seeded behind the seam, inside `SessionEnvironment.live`'s
///   `ConfigLoader`, so it is the Kit's `ConfigLoader` and restore-pipeline
///   tests that pin it, not these;
/// - the copy each failure puts on the form, and that a failure wires,
///   records and remembers nothing. A `NotAuthorizedException` here is a bad
///   password; the refused-refresh reading of the same Cognito code (#1288)
///   belongs to restore, not to this path.
///
/// `SignInOverASessionCharacterizationTests` below pins a sign-in that starts
/// while a session is already wired. The second factor and the different-user
/// cache wipe are in `SignInMfaCharacterizationTests.swift`.
@MainActor
final class SignInCharacterizationTests: XCTestCase {
    private var world: SessionHarness!

    override func setUp() async throws {
        world = try SessionHarness()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    private func signIn(domain: String = SignInScript.domain) async {
        await world.appState.signIn(controlDomain: domain, username: "alice", password: SignInScript.password)
    }

    // MARK: - Success

    /// `.signingIn` is set before the first await, with the prologue's clears:
    /// the code form's error and the form's explanation are gone while
    /// config.json is still loading. (The parked challenge it also drops is
    /// `SignInMfaCharacterizationTests.testANewSignInDropsAParkedChallenge`.)
    func testSigningInShowsWhileTheConfigurationLoadsWithTheFormStateCleared() async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))
        world.appState.sessionManager.signedOutReason = .sessionExpired
        world.appState.sessionManager.mfaError = "left over from a code form"
        world.holdNextConfigurationLoad()

        let signIn = Task { await self.signIn() }
        await SignInScript.awaitHeldLoad(in: world)

        XCTAssertEqual(world.appState.status, .signingIn)
        XCTAssertNil(world.appState.signedOutReason)
        XCTAssertNil(world.appState.mfaError)
        XCTAssertNil(world.appState.client)
        XCTAssertEqual(world.events, ["loadConfiguration cabalmail.example"])

        world.releaseConfigurationLoad()
        await signIn.value
        XCTAssertEqual(world.appState.status, .signedIn)
    }

    /// The order is what the session manager has to keep: the client is built
    /// over the secure store, the domain is remembered (and mirrored to the
    /// Safari extension) before anything is wired, the badge and contacts
    /// prompts come from wiring, and the platform hooks run with the tokens
    /// stored.
    func testASuccessfulSignInBuildsWiresAndHandsOffInThisOrder() async throws {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))

        await signIn()

        XCTAssertEqual(world.events, SignInScript.clientBuilt + SignInScript.wired("alice"))
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.clients.count, 1)
        XCTAssertTrue(world.appState.client === world.clients.first, "the client it built is the one wired")
        XCTAssertNotNil(world.appState.navCoordinator)
        let observer = try XCTUnwrap(world.appState.sessionManager.sessionExpiryTask, "the session observer runs")
        XCTAssertFalse(observer.isCancelled)
        XCTAssertNil(world.appState.signedOutReason)
        XCTAssertNil(world.appState.mfaError)
    }

    func testASuccessfulSignInRemembersTheDomainAndUsernameAndStoresTheTokens() async throws {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A", refresh: "REFRESH-A"))

        await signIn()

        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), "cabalmail.example")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "alice")
        XCTAssertTrue(world.hasStoredTokens)
        let client = try XCTUnwrap(world.appState.client)
        let tokens = await client.authService.currentTokens()
        XCTAssertEqual(tokens?.idToken, "ID-A")
        XCTAssertEqual(tokens?.refreshToken, "REFRESH-A")
    }

    func testSignInMakesOnePasswordAuthCarryingTheCredentials() async throws {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))

        await signIn()

        let trail = await world.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH"])
        let requests = await world.cognito.requests
        let body = try SignInScript.jsonBody(of: requests.first)
        XCTAssertEqual(body["AuthFlow"] as? String, "USER_PASSWORD_AUTH")
        XCTAssertEqual(body["ClientId"] as? String, "c")
        let parameters = try XCTUnwrap(body["AuthParameters"] as? [String: String])
        XCTAssertEqual(parameters, ["USERNAME": "alice", "PASSWORD": "hunter2"])
    }

    /// AppState normalizes nothing: the domain as typed is what config.json is
    /// loaded for, what the next launch restores from and what the Safari
    /// extension is handed. (Neither AppState nor `ConfigLoader` lower-cases
    /// it.)
    func testTheDomainIsLoadedAndRememberedAsTyped() async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))

        await signIn(domain: "CabalMail.Example")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.events.first, "loadConfiguration CabalMail.Example")
        XCTAssertTrue(world.events.contains("publishControlDomain CabalMail.Example"), "\(world.events)")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), "CabalMail.Example")
    }

    /// Where AppState and `ConfigLoader` part ways: the loader trims the field
    /// and strips an `https://` or `http://` before fetching config.json, but
    /// AppState remembers the raw field for the next launch and hands it, raw,
    /// to the Safari extension. (SignInView passes the field untrimmed.)
    func testADomainTypedWithASchemeAndSpacesIsRememberedAndPublishedRaw() async {
        let typed = " https://cabalmail.example "
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))

        await signIn(domain: typed)

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.events.first, "loadConfiguration \(typed)")
        XCTAssertTrue(world.events.contains("publishControlDomain \(typed)"), "\(world.events)")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), typed)
        XCTAssertEqual(world.appState.controlDomain, typed)
    }

    // MARK: - Failures before a client exists

    func testAConfigurationLoadThatCannotReachTheServerShowsTheNetworkCopy() async {
        world.configurationResult = .failure(CabalmailError.network("offline"))
        await assertFailedSignIn(shows: "Network error: offline", events: SignInScript.configurationOnly)
    }

    func testAnUnknownControlDomainShowsTheInvalidDomainCopy() async {
        world.configurationResult = .failure(CabalmailError.notConfigured)
        await assertFailedSignIn(shows: "Control domain is invalid.", events: SignInScript.configurationOnly)
    }

    func testAnUndecodableConfigurationShowsTheResponseCopy() async {
        world.configurationResult = .failure(CabalmailError.decoding("config.json is not JSON"))
        await assertFailedSignIn(
            shows: "Response error: config.json is not JSON", events: SignInScript.configurationOnly
        )
    }

    /// Anything that is not a `CabalmailError` shows its own description.
    func testAConfigurationFailureThatIsNotACabalmailErrorShowsItsDescription() async {
        world.configurationResult = .failure(DescribedFailure(text: "The certificate for this server is invalid."))
        await assertFailedSignIn(
            shows: "The certificate for this server is invalid.", events: SignInScript.configurationOnly
        )
    }

    /// Production's factory throws when Application Support is unusable.
    func testAClientThatCannotBeBuiltShowsItsDescription() async {
        world.makeClientFailure = DescribedFailure(text: "Application Support is not writable.")
        await assertFailedSignIn(shows: "Application Support is not writable.", events: SignInScript.clientBuilt)
        XCTAssertTrue(world.clients.isEmpty)
    }

    // MARK: - Failures from Cognito

    func testABadPasswordShowsTheInvalidCredentialsCopy() async {
        await assertRefusal(.error(type: "NotAuthorizedException"), shows: "Incorrect username or password.")
    }

    func testAnUnconfirmedAccountShowsCognitosMessageAsAServerError() async {
        await assertRefusal(
            .error(type: "UserNotConfirmedException", message: "User is not confirmed."),
            shows: "Server error: User is not confirmed."
        )
    }

    func testARequiredPasswordResetShowsCognitosMessageAsAServerError() async {
        await assertRefusal(
            .error(type: "PasswordResetRequiredException", message: "Password reset required for the user"),
            shows: "Server error: Password reset required for the user"
        )
    }

    /// A pool trigger's refusal (the MFA-enrollment gate, the invite check)
    /// shows the trigger's own sentence, unwrapped and without a prefix.
    func testAPoolTriggerRejectionShowsTheTriggersOwnCopy() async {
        await assertRefusal(
            .error(
                type: "UserLambdaValidationException",
                message: "PreAuthentication failed with error Sign-in requires an authenticator app.."
            ),
            shows: "Sign-in requires an authenticator app."
        )
    }

    func testAnUnreachableCognitoShowsTheNetworkCopy() async {
        await assertRefusal(.unreachable, shows: "Network error: The Internet connection appears to be offline.")
    }

    /// A challenge the app has no form for is a failure, not a code form.
    func testAnUnhandledChallengeShowsTheProtocolCopy() async {
        await assertRefusal(
            .challenge(name: "NEW_PASSWORD_REQUIRED", session: "SESSION-1"),
            shows: "Protocol error: Unhandled challenge: NEW_PASSWORD_REQUIRED"
        )
    }

    /// The last session is written only on success, so a failed sign-in as
    /// someone else leaves the previous one for the next launch to restore.
    func testAFailedSignInLeavesThePreviousLastSessionInPlace() async {
        world.seedLastSession(controlDomain: "old.example", username: "bob")
        await world.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await signIn()

        XCTAssertEqual(world.appState.status, .error("Incorrect username or password."))
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), "old.example")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "bob")
        XCTAssertEqual(world.events, SignInScript.clientBuilt, "the domain is not re-published")
    }

    // MARK: - Helpers

    private func assertRefusal(
        _ answer: ScriptedCognito.Answer,
        shows text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await world.cognito.script(.passwordSignIn, answer)
        await assertFailedSignIn(shows: text, events: SignInScript.clientBuilt, file: file, line: line)
        XCTAssertEqual(world.clients.count, 1, "the client is built, then dropped", file: file, line: line)
    }

    /// Signs in as alice and pins what every failure shares: the copy on the
    /// form, and that nothing was wired, recorded, stored or remembered.
    private func assertFailedSignIn(
        shows text: String,
        events expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await signIn()
        let state = world.appState
        XCTAssertEqual(state.status, .error(text), file: file, line: line)
        XCTAssertNil(state.client, "nothing is wired", file: file, line: line)
        XCTAssertNil(state.navCoordinator, file: file, line: line)
        XCTAssertNil(state.sessionManager.sessionExpiryTask, "no session observer", file: file, line: line)
        XCTAssertEqual(world.events, expected, "no session hook ran", file: file, line: line)
        XCTAssertFalse(world.hasStoredTokens, "no tokens", file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.domainKey), file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.usernameKey), file: file, line: line)
    }
}

/// A sign-in that arrives while a session is already wired (#2559). One
/// account per install: `signIn` refuses it, logs a line and changes
/// nothing, so the only way to another account is Sign Out, then Sign In.
/// SignInView is `signIn`'s only caller and is shown only while signed out,
/// so no screen reaches this; #1826's status-only exits (a stray
/// `submitMfaCode` or `cancelMfaChallenge` put the sign-in form over a client
/// that was still wired) were the app's way here, and both are now ignored
/// off the code form.
///
/// Workstream 0.8 pinned what used to happen instead, as latent defects: the
/// second sign-in replaced the first session without ending it (no push
/// deregistration, no wipe), another account's sign-in wiped the shared
/// cache under a session nobody ended, and a failed one left an error on the
/// status over a session that kept running. Each test below is one of those
/// pins, turned into a test of the rule (account-isolation.md, decision 3).
///
/// The harness builds each client over a cache directory of its own, where
/// production builds every client over one shared Application Support
/// directory. Where that matters (another account's sign-in must not wipe
/// the cache the session uses), the clients the environment would build next
/// are seated over the first client's caches to stand in for the shared
/// directory.
@MainActor
final class SignInOverASessionCharacterizationTests: XCTestCase {
    private var world: SessionHarness!

    override func setUp() async throws {
        world = try SessionHarness()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// The refusal comes before anything is shown or asked for: the status
    /// never leaves `.signedIn` for `.signingIn`, and no configuration is
    /// loaded.
    func testASignInOverASessionIsRefusedBeforeAnythingLoads() async throws {
        let first = try await signInFirst()
        let observer = try XCTUnwrap(world.appState.sessionManager.sessionExpiryTask)
        let before = world.events.count

        await signIn(as: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertTrue(world.appState.client === first)
        XCTAssertFalse(observer.isCancelled)
        XCTAssertEqual(Array(world.events.dropFirst(before)), [], "no configuration load, nothing built")
    }

    /// A second sign-in as the same account replaces nothing: the first
    /// session keeps its client, navigation, observer, tokens and cached
    /// mail, no client is built, and Cognito is not asked.
    func testASecondSignInOverASessionReplacesNothing() async throws {
        let first = try await signInFirst()
        let firstNavigation = try XCTUnwrap(world.appState.navCoordinator)
        let firstObserver = try XCTUnwrap(world.appState.sessionManager.sessionExpiryTask)
        let firstMail = SignInCachedMail(of: first)
        try await firstMail.seed()
        let before = world.events.count
        let asked = await world.cognito.trail

        await signIn(as: "alice")

        XCTAssertEqual(Array(world.events.dropFirst(before)), [])
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.clients.count, 1)
        XCTAssertTrue(world.appState.client === first)
        XCTAssertTrue(world.appState.navCoordinator === firstNavigation)
        XCTAssertFalse(firstObserver.isCancelled)
        XCTAssertTrue(world.appState.sessionManager.sessionExpiryTask == firstObserver)
        await firstMail.assertPresent(true)
        let tokens = await world.appState.client?.authService.currentTokens()
        XCTAssertEqual(tokens?.idToken, "ID-A", "the first session's tokens stand")
        let trail = await world.cognito.trail
        XCTAssertEqual(trail, asked, "Cognito was not asked")
    }

    /// Another account's sign-in over a session is refused like any other:
    /// the different-account wipe does not run, so the cached mail the
    /// session is using stays, the remembered account stays, and the watch
    /// is handed nothing.
    func testASignInAsAnotherAccountOverASessionWipesNothing() async throws {
        let first = try await signInFirst()
        let sharedMail = SignInCachedMail(of: first)
        try await sharedMail.seed()
        SignInScript.seatClients(of: world, over: sharedMail)
        let before = world.events.count

        await signIn(as: "bob")

        XCTAssertEqual(Array(world.events.dropFirst(before)), [])
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertTrue(world.appState.client === first)
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "alice")
        await sharedMail.assertPresent(true)
    }

    /// A sign-in that Cognito would refuse never reaches Cognito: the
    /// status keeps saying signed in, as the client, observer and stored
    /// tokens do, and no error is put over the session.
    func testASignInThatWouldFailOverASessionShowsNoError() async throws {
        let first = try await signInFirst()
        let observer = try XCTUnwrap(world.appState.sessionManager.sessionExpiryTask)
        let before = world.events.count
        await world.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await signIn(as: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertTrue(world.appState.client === first)
        XCTAssertFalse(observer.isCancelled)
        XCTAssertEqual(Array(world.events.dropFirst(before)), [])
        XCTAssertTrue(world.hasStoredTokens, "the first session's tokens are still stored")
    }

    /// After a Sign Out the same sign-in goes through: the rule refuses a
    /// sign-in over a session, not a second sign-in.
    func testASignInAfterSignOutIsNotRefused() async throws {
        let first = try await signInFirst()
        await world.appState.signOut()
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-B"))

        await signIn(as: "bob")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertFalse(world.appState.client === first)
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "bob")
    }

    private func signIn(as username: String) async {
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
    }

    /// Signs alice in and returns the wired client.
    private func signInFirst() async throws -> CabalmailClient {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))
        await signIn(as: "alice")
        XCTAssertEqual(world.appState.status, .signedIn, "precondition")
        return try XCTUnwrap(world.appState.client)
    }
}

/// A failure that is not a `CabalmailError`, with a fixed description.
private struct DescribedFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
