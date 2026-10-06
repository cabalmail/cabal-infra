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
        world.appState.signedOutReason = .sessionExpired
        world.appState.mfaError = "left over from a code form"
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
        let observer = try XCTUnwrap(world.appState.sessionExpiryTask, "the session observer runs")
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
        XCTAssertNil(state.sessionExpiryTask, "no session observer", file: file, line: line)
        XCTAssertEqual(world.events, expected, "no session hook ran", file: file, line: line)
        XCTAssertFalse(world.hasStoredTokens, "no tokens", file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.domainKey), file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.usernameKey), file: file, line: line)
    }
}

/// Characterization suite for workstream 0.8: a sign-in that starts while a
/// session is already wired. `signIn` has no guard for it (restore has one: it
/// returns while a client is wired). SignInView is its only caller and is
/// shown only while signed out. #1826's status-only exits (a stray
/// `submitMfaCode` or `cancelMfaChallenge` put the sign-in form over a client
/// that was still wired) were the app's way here, and both are now ignored
/// off the code form. The per-account session manager will own exactly this
/// case (an account added beside another), so what happens to the first
/// session is pinned: nothing ends it.
///
/// The harness builds each client over a cache directory of its own, where
/// production builds every client over one shared Application Support
/// directory. Where that matters (another account's sign-in wiping the cache
/// the first session still uses), the second client is seated over the first
/// client's caches to stand in for the shared directory.
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

    /// While the second sign-in loads its configuration the first session is
    /// still wired and observed, under `.signingIn`.
    func testTheFirstSessionStaysWiredWhileTheSecondSignInLoads() async throws {
        let first = try await signInFirst()
        let observer = try XCTUnwrap(world.appState.sessionExpiryTask)
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-B"))
        world.holdNextConfigurationLoad()

        let second = Task { await self.signIn(as: "alice") }
        await SignInScript.awaitHeldLoad(in: world)

        XCTAssertEqual(world.appState.status, .signingIn)
        XCTAssertTrue(world.appState.client === first)
        XCTAssertFalse(observer.isCancelled)
        world.releaseConfigurationLoad()
        await second.value
        XCTAssertEqual(world.appState.status, .signedIn)
    }

    /// Pins current behaviour, which looks like a latent defect: the second
    /// session replaces the first's client, navigation and observer, but
    /// nothing ends the first: no `sessionWillEnd` (push deregistration), no
    /// local wipe, no `sessionDidEnd`. The badge and feed pollers the first
    /// sign-in started keep running (each reads `client` on every tick, so
    /// they now poll the new client), so the badge prompt is not requested
    /// again; the contacts prompt and the platform hooks are.
    /// Tracked in #1826.
    func testASecondSignInReplacesTheSessionWithoutEndingTheFirst() async throws {
        let first = try await signInFirst()
        let firstNavigation = try XCTUnwrap(world.appState.navCoordinator)
        let firstObserver = try XCTUnwrap(world.appState.sessionExpiryTask)
        let firstMail = SignInCachedMail(of: first)
        try await firstMail.seed()
        let before = world.events.count
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-B"))

        await signIn(as: "alice")

        XCTAssertEqual(Array(world.events.dropFirst(before)), SignInScript.rewired("alice"))
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertTrue(world.appState.client === world.clients.last)
        XCTAssertFalse(world.appState.client === first)
        XCTAssertFalse(world.appState.navCoordinator === firstNavigation)
        XCTAssertTrue(firstObserver.isCancelled, "observing again replaced the first observer")
        XCTAssertEqual(world.appState.sessionExpiryTask?.isCancelled, false)
        await firstMail.assertPresent(true)
        let tokens = await world.appState.client?.authService.currentTokens()
        XCTAssertEqual(tokens?.idToken, "ID-B", "the second sign-in's tokens replaced the first's")
    }

    /// Pins current behaviour, which looks like a latent defect: another
    /// account's sign-in does not end the first account's session either. No
    /// `sessionWillEnd` runs, so the first account's push registration (a row
    /// per user and device token) is never withdrawn, and no `sessionDidEnd`;
    /// the watch is simply handed the second account. What does run is the
    /// different-user rule, on the new client, and because production's
    /// clients share one cache directory, that wipe takes the first account's
    /// cached mail out from under a session nobody ended.
    /// Tracked in #1826.
    func testASignInAsAnotherAccountOverASessionWipesTheSharedCacheButNeverEndsTheFirst() async throws {
        let first = try await signInFirst()
        let sharedMail = SignInCachedMail(of: first)
        try await sharedMail.seed()
        SignInScript.seatClients(of: world, over: sharedMail)
        let before = world.events.count
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-B"))

        await signIn(as: "bob")

        XCTAssertEqual(Array(world.events.dropFirst(before)), SignInScript.rewired("bob"))
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertFalse(world.appState.client === first)
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "bob")
        await sharedMail.assertPresent(false)
    }

    /// Pins current behaviour, which looks like a latent defect: a second
    /// sign-in that fails puts its error on the status while the first
    /// session stays wired and observed with its tokens stored. The status
    /// says the sign-in form; the client, observer and pollers say signed in.
    /// Tracked in #1826.
    func testAFailedSignInOverASessionShowsAnErrorWhileTheSessionStaysWired() async throws {
        let first = try await signInFirst()
        let observer = try XCTUnwrap(world.appState.sessionExpiryTask)
        let before = world.events.count
        await world.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await signIn(as: "alice")

        XCTAssertEqual(world.appState.status, .error("Incorrect username or password."))
        XCTAssertTrue(world.appState.client === first)
        XCTAssertFalse(observer.isCancelled)
        XCTAssertEqual(Array(world.events.dropFirst(before)), SignInScript.clientBuilt)
        XCTAssertTrue(world.hasStoredTokens, "the first session's tokens are still stored")
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
