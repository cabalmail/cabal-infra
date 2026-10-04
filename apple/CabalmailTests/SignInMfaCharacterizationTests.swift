import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8: the second factor (identity
/// plan Phase 1, the MFA work) through `AppState`, driven end to end through
/// `SessionHarness`: `signIn` parking a challenge, `submitMfaCode` and
/// `cancelMfaChallenge`. The Kit's half (how Cognito's answers map to
/// errors, which challenge session it keeps) is `AuthMfaCharacterizationTests`;
/// these pin what the app does with each answer: the status, the code form's
/// error, what is wired, recorded and remembered, and whether the parked
/// challenge survives. Workstream 1.3 moves this flow into the per-account
/// session manager.
///
/// `pendingMfa` is private, so a dropped challenge is shown the one way it
/// can be: with the status put back on the code form, a code submitted
/// afterwards never reaches Cognito.
///
/// Protects the #1807 fix (an expired challenge reads as an expired session,
/// not a bad password). The stray
/// submit and cancel of #1826 are `SessionLifecycleCharacterizationTests`.
@MainActor
final class SignInMfaCharacterizationTests: XCTestCase {
    private var world: SessionHarness!

    override func setUp() async throws {
        world = try SessionHarness()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    // MARK: - The challenge

    /// The password is accepted and the client is built, then parked with the
    /// challenge: no tokens exist yet, so nothing is wired or remembered.
    func testATotpChallengeShowsTheCodeFormWithNothingWired() async {
        await challenge("SOFTWARE_TOKEN_MFA")

        XCTAssertEqual(world.appState.status, .mfaCodeRequired(.totp))
        XCTAssertNil(world.appState.mfaError)
        XCTAssertEqual(world.clients.count, 1, "the client is built and parked")
        await assertNothingWired()
    }

    func testAnSmsChallengeShowsTheCodeFormAndItsCodeSignsIn() async {
        await challenge("SMS_MFA")

        XCTAssertEqual(world.appState.status, .mfaCodeRequired(.sms))
        await assertNothingWired()

        await world.cognito.script(.mfaAnswer, .tokens(id: "ID-MFA"))
        await world.appState.submitMfaCode("654321")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.events, SignInScript.clientBuilt + SignInScript.wired("alice"))
    }

    // MARK: - Answering it

    /// The parked client is the one wired (no second client is built), and
    /// the wiring is a password sign-in's, event for event.
    func testACorrectCodeWiresTheParkedClientExactlyLikeAPasswordSignIn() async throws {
        await challenge("SOFTWARE_TOKEN_MFA")
        await world.cognito.script(.mfaAnswer, .tokens(id: "ID-MFA"))

        await world.appState.submitMfaCode("123456")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(world.events, SignInScript.clientBuilt + SignInScript.wired("alice"))
        XCTAssertEqual(world.clients.count, 1)
        XCTAssertTrue(world.appState.client === world.clients.first)
        XCTAssertNotNil(world.appState.navCoordinator)
        XCTAssertNotNil(world.appState.sessionExpiryTask)
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), "cabalmail.example")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "alice")
        let tokens = await world.appState.client?.authService.currentTokens()
        XCTAssertEqual(tokens?.idToken, "ID-MFA")
        let trail = await world.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH", "RespondToAuthChallenge"])
        let requests = await world.cognito.requests
        let answer = try SignInScript.jsonBody(of: requests.last)
        XCTAssertEqual(answer["Session"] as? String, "SESSION-1")
        let responses = answer["ChallengeResponses"] as? [String: String]
        XCTAssertEqual(responses?["SOFTWARE_TOKEN_MFA_CODE"], "123456")
    }

    /// A mistyped code keeps the code form with its own error, and the same
    /// challenge still accepts the next code; that submit clears the error.
    func testAMismatchedCodeKeepsTheCodeFormAndALaterCodeStillSignsIn() async throws {
        await challenge("SOFTWARE_TOKEN_MFA")
        await world.cognito.script(
            .mfaAnswer,
            .error(type: "CodeMismatchException", message: "Invalid code received for user"),
            .tokens(id: "ID-MFA")
        )

        await world.appState.submitMfaCode("000000")

        XCTAssertEqual(world.appState.status, .mfaCodeRequired(.totp))
        XCTAssertEqual(world.appState.mfaError, SignInScript.mismatch)
        await assertNothingWired()

        await world.appState.submitMfaCode("123456")

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertNil(world.appState.mfaError)
        XCTAssertEqual(world.events, SignInScript.clientBuilt + SignInScript.wired("alice"))
        let requests = await world.cognito.requests
        let sessions = try requests.dropFirst().map { try SignInScript.jsonBody(of: $0)["Session"] as? String }
        XCTAssertEqual(sessions, ["SESSION-1", "SESSION-1"], "both codes answer the one challenge")
    }

    /// Cognito refuses a code sent after the challenge session expired with
    /// `NotAuthorizedException`. The auth service reads that as `.authExpired`
    /// on the challenge, so the form says the session expired rather than
    /// that the password was wrong (#1807; before, it said "Incorrect username
    /// or password."). The challenge is dropped with it.
    func testAnExpiredChallengeSaysTheSessionExpiredAndDropsTheChallenge() async {
        await assertAnswerRestartsSignIn(
            .error(type: "NotAuthorizedException", message: "Invalid session for the user, session is expired."),
            shows: "Session expired. Please sign in again."
        )
    }

    /// Pins current behaviour, which may be a defect, though nothing verifies
    /// it: only `CodeMismatchException` keeps the code form. Any other refusal
    /// of the code, for example `ExpiredCodeException` with the text Cognito
    /// is reported to send for a TOTP code already used once (unconfirmed
    /// against a real pool), drops the challenge and sends the user back to
    /// retype the password, with Cognito's text. The Kit keeps its parked
    /// challenge on every error, so a fresh code could be sent, but AppState
    /// calls the restart deliberate ("challenge session expired, throttled,
    /// ..."). It is a defect only if Cognito's challenge session still takes
    /// a code after such a refusal, which is unverified.
    func testAReusedCodeRestartsFromThePasswordFormWithTheServerCopy() async {
        await assertAnswerRestartsSignIn(
            .error(type: "ExpiredCodeException", message: "Your software token has already been used once."),
            shows: "Server error: Your software token has already been used once."
        )
    }

    /// Pins current behaviour, which may be a defect, by the same reading as
    /// the reused code above: a code that never reached Cognito drops the
    /// challenge too, so the password is typed again once back online,
    /// although Cognito saw nothing and the Kit still holds the challenge
    /// session. Whether a network blip should cost the password is a product
    /// call; AppState's catch-all restart makes it today.
    func testAnUnreachableCognitoOnTheCodeDropsTheChallenge() async {
        await assertAnswerRestartsSignIn(
            .unreachable, shows: "Network error: The Internet connection appears to be offline."
        )
    }

    // MARK: - Leaving it

    /// Back from the code form: the challenge and its error go, and the
    /// parked client is dropped without anything having been wired.
    func testCancellingTheCodeFormDropsTheChallengeWithNothingWired() async {
        await challenge("SOFTWARE_TOKEN_MFA")
        await world.cognito.script(.mfaAnswer, .error(type: "CodeMismatchException"))
        await world.appState.submitMfaCode("000000")
        XCTAssertEqual(world.appState.mfaError, SignInScript.mismatch, "precondition")

        world.appState.cancelMfaChallenge()

        XCTAssertEqual(world.appState.status, .signedOut)
        XCTAssertNil(world.appState.mfaError)
        await assertNothingWired()
        await assertChallengeDropped(answersSoFar: 1)
    }

    /// `signIn`'s prologue drops a parked challenge and the code form's error
    /// before its first await, so they are gone even when that sign-in fails.
    func testANewSignInDropsAParkedChallenge() async {
        await challenge("SOFTWARE_TOKEN_MFA")
        await world.cognito.script(.mfaAnswer, .error(type: "CodeMismatchException"))
        await world.appState.submitMfaCode("000000")
        world.configurationResult = .failure(CabalmailError.network("offline"))
        world.holdNextConfigurationLoad()

        let again = Task {
            await self.world.appState.signIn(
                controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
            )
        }
        await SignInScript.awaitHeldLoad(in: world)

        XCTAssertEqual(world.appState.status, .signingIn)
        XCTAssertNil(world.appState.mfaError)
        world.releaseConfigurationLoad()
        await again.value
        XCTAssertEqual(world.appState.status, .error("Network error: offline"))
        await assertChallengeDropped(answersSoFar: 1)
    }

    // MARK: - Helpers

    /// Signs in as alice with Cognito answering the password with `name`.
    private func challenge(_ name: String) async {
        await world.cognito.script(.passwordSignIn, .challenge(name: name, session: "SESSION-1"))
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
    }

    /// A refused code that ends the challenge: the copy goes on the password
    /// form, the code form's error is cleared, and nothing is wired.
    private func assertAnswerRestartsSignIn(
        _ answer: ScriptedCognito.Answer,
        shows text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await challenge("SOFTWARE_TOKEN_MFA")
        await world.cognito.script(.mfaAnswer, answer)

        await world.appState.submitMfaCode("123456")

        XCTAssertEqual(world.appState.status, .error(text), file: file, line: line)
        XCTAssertNil(world.appState.mfaError, file: file, line: line)
        await assertNothingWired(file: file, line: line)
        await assertChallengeDropped(answersSoFar: 1, file: file, line: line)
    }

    /// The code form's state with no session: the client built for the
    /// challenge is not wired, no hook ran, and nothing is stored or
    /// remembered.
    private func assertNothingWired(file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertNil(world.appState.client, file: file, line: line)
        XCTAssertNil(world.appState.navCoordinator, file: file, line: line)
        XCTAssertNil(world.appState.sessionExpiryTask, file: file, line: line)
        XCTAssertEqual(world.events, SignInScript.clientBuilt, "no session hook ran", file: file, line: line)
        XCTAssertFalse(world.hasStoredTokens, file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.domainKey), file: file, line: line)
        XCTAssertNil(world.defaults.string(forKey: SignInScript.usernameKey), file: file, line: line)
    }

    /// With the status put back on the code form, a code goes nowhere: the
    /// guard finds no parked challenge and returns to the password form
    /// without asking Cognito.
    private func assertChallengeDropped(
        answersSoFar: Int, file: StaticString = #filePath, line: UInt = #line
    ) async {
        world.appState.status = .mfaCodeRequired(.totp)
        await world.appState.submitMfaCode("999999")
        XCTAssertEqual(world.appState.status, .signedOut, file: file, line: line)
        let answers = await world.cognito.trail.filter { $0 == "RespondToAuthChallenge" }.count
        XCTAssertEqual(answers, answersSoFar, "no code reached Cognito", file: file, line: line)
    }
}

/// Characterization suite for workstream 0.8: `completeInteractiveSignIn`'s
/// different-user rule, the defense in depth for a force-quit that skipped
/// sign-out's wipe (the sibling of #1825's sign-out leftovers). When a
/// username is remembered and differs from the one signing in, the new
/// client's cached mail is wiped before the session is wired; otherwise it is
/// kept. Both entry paths run it.
///
/// The code form is the natural window for seeding: the client is built and
/// parked, and nothing has been wiped yet. The password path has no such gap,
/// so its tests seat the sign-in's client over caches seeded first. A probe at
/// the first environment call inside `wireSession` (building the navigation
/// coordinator) shows the wipe came before the wiring.
@MainActor
final class SignInDifferentUserCharacterizationTests: XCTestCase {
    private var world: SessionHarness!
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("signin-different-user-\(UUID().uuidString)")

    override func setUp() async throws {
        world = try SessionHarness()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAnotherAccountAfterTheCodeWipesTheParkedClientsMailBeforeWiring() async throws {
        world.seedLastSession(username: "bob")
        let mail = try await parkChallengeOverCachedMail()
        XCTAssertEqual(
            world.defaults.string(forKey: SignInScript.usernameKey), "bob", "the code form remembers nothing"
        )
        let probe = WiringProbe(on: world, watching: await mail.bodies.directory)

        await answerTheCode()

        XCTAssertEqual(probe.bodiesWhenWiringBegan, 0, "wiped before wiring")
        await mail.assertPresent(false)
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.usernameKey), "alice")
    }

    func testTheSameAccountAfterTheCodeKeepsTheParkedClientsMail() async throws {
        world.seedLastSession(username: "alice")
        let mail = try await parkChallengeOverCachedMail()
        let probe = WiringProbe(on: world, watching: await mail.bodies.directory)

        await answerTheCode()

        XCTAssertEqual(probe.bodiesWhenWiringBegan, 1)
        await mail.assertPresent(true)
    }

    /// No remembered username is no previous account.
    func testAFirstSignInOnThisInstallKeepsTheParkedClientsMail() async throws {
        let mail = try await parkChallengeOverCachedMail()

        await answerTheCode()

        await mail.assertPresent(true)
    }

    /// Pins current behaviour: the comparison is exact, so the remembered
    /// "Alice" and a sign-in as "alice" count as two accounts, and the cached
    /// mail is wiped (it is fetched again; the server copy is untouched). Not a
    /// quirk: the user pool sets no `username_configuration`, so Cognito's
    /// default, case-sensitive usernames, applies, and these are two accounts.
    func testAUsernameThatDiffersOnlyInCaseCountsAsAnotherAccount() async throws {
        world.seedLastSession(username: "Alice")
        let mail = try await parkChallengeOverCachedMail()

        await answerTheCode()

        await mail.assertPresent(false)
    }

    func testAnotherAccountOnThePasswordPathWipesTheNewClientsMailBeforeWiring() async throws {
        world.seedLastSession(username: "bob")
        let mail = try await seatTheNextClientOverCachedMail()
        let probe = WiringProbe(on: world, watching: await mail.bodies.directory)

        await signInWithPassword()

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(probe.bodiesWhenWiringBegan, 0, "wiped before wiring")
        await mail.assertPresent(false)
    }

    func testTheSameAccountOnThePasswordPathKeepsTheNewClientsMail() async throws {
        world.seedLastSession(username: "alice")
        let mail = try await seatTheNextClientOverCachedMail()
        let probe = WiringProbe(on: world, watching: await mail.bodies.directory)

        await signInWithPassword()

        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertEqual(probe.bodiesWhenWiringBegan, 1)
        await mail.assertPresent(true)
    }

    // MARK: - Helpers

    /// Parks alice's TOTP challenge and seeds the parked client's caches.
    private func parkChallengeOverCachedMail() async throws -> SignInCachedMail {
        await world.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "SESSION-1"))
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
        XCTAssertEqual(world.appState.status, .mfaCodeRequired(.totp), "precondition")
        let mail = SignInCachedMail(of: try XCTUnwrap(world.clients.first))
        try await mail.seed()
        return mail
    }

    /// Seeds caches in the scratch directory and seats the clients the
    /// environment builds from here on over them.
    private func seatTheNextClientOverCachedMail() async throws -> SignInCachedMail {
        let mail = try SignInCachedMail(directory: scratch)
        try await mail.seed()
        SignInScript.seatClients(of: world, over: mail)
        return mail
    }

    private func answerTheCode() async {
        await world.cognito.script(.mfaAnswer, .tokens(id: "ID-MFA"))
        await world.appState.submitMfaCode("123456")
        XCTAssertEqual(world.appState.status, .signedIn, "precondition")
    }

    private func signInWithPassword() async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-A"))
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
    }
}

/// Counts the cached bodies in a body-cache directory at the moment
/// `wireSession` asks the environment for a navigation coordinator, its first
/// environment call after installing the client.
@MainActor
private final class WiringProbe {
    private(set) var bodiesWhenWiringBegan: Int?

    init(on world: SessionHarness, watching directory: URL) {
        let makeNavCoordinator = world.appState.sessionEnvironment.makeNavCoordinator
        world.appState.sessionEnvironment.makeNavCoordinator = { [self] client in
            let paths = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
            bodiesWhenWiringBegan = paths.filter { $0.hasSuffix(".eml") }.count
            return makeNavCoordinator(client)
        }
    }
}
