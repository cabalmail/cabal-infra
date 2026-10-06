import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One client per account (workstream 1.3). The background paths — a
/// notification action, an App Intent, the macOS silent-push enrichment —
/// used to build clients of their own on a launch with no session: from an
/// uncached config.json, with no expiry observer, and each with a send queue
/// draining the one outbox the session's client drains. They now borrow from
/// the session manager: the wired session's client, or, with none, the stored
/// account's, built once through the restore's environment and adopted by the
/// restore. A client the manager lets go is shut down.
@MainActor
final class SessionClientLendingTests: XCTestCase {
    private var harness: SessionHarness!
    private var defaults: UserDefaults!
    private var suiteName = ""

    private var manager: SessionManager { harness.appState.sessionManager }

    override func setUp() async throws {
        harness = try SessionHarness()
        suiteName = "session-lending-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - With a session

    /// Every borrower gets the session's client, the push registrar's
    /// notification actions included, and nothing builds a second one.
    func testBorrowersGetTheWiredSessionsClient() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let wired = try XCTUnwrap(harness.appState.client)

        let lent = try await manager.borrowClient()
        await makeRegistrar().handleNotificationAction(identifier: "MARK_READ", ref: try Self.pushRef())

        XCTAssertTrue(lent === wired)
        let calls = await harness.imap.flagCalls
        XCTAssertEqual(calls.map(\.uids), [[4271]], "the action ran")
        XCTAssertEqual(harness.clients.count, 1, "nothing built a second client")
    }

    /// Sign-out shuts the session's client down, and with the tokens gone a
    /// borrower gets nothing.
    func testSignOutShutsTheClientDownAndBorrowersLoseIt() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let wired = try XCTUnwrap(harness.appState.client)

        await harness.appState.signOut()

        let isShutDown = await wired.isShutDown
        XCTAssertTrue(isShutDown, "sign-out shut the client down")
        let lent = try await manager.borrowClient()
        XCTAssertNil(lent)
    }

    // MARK: - Without one

    /// A background launch: no scene, so no restore, and a borrower asks.
    /// The manager builds the stored account's client once, through the
    /// restore's environment, and wires no session; the restore that runs
    /// when the app comes forward adopts it.
    func testABackgroundBorrowThenARestoreBuildOneClient() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()

        let borrowed = try await manager.borrowClient()
        let lent = try XCTUnwrap(borrowed)
        XCTAssertEqual(harness.appState.status, .signedOut, "lending wires no session")
        XCTAssertNil(harness.appState.client)
        let again = try await manager.borrowClient()
        XCTAssertTrue(again === lent, "a second borrow reuses it")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertTrue(harness.appState.client === lent, "the restore adopted the borrowed client")
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertEqual(count(of: "loadConfiguration cabalmail.example"), 1)
    }

    /// The same with the borrow's config.json load held: a restore that
    /// starts meanwhile waits for that build rather than start its own.
    func testARestoreWaitsForABorrowsBuildInFlight() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.holdNextConfigurationLoad()
        let manager = self.manager
        let borrow = Task { try await manager.borrowClient() }
        await SignInScript.awaitHeldLoad(in: harness)
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(appState.status, .restoring)

        harness.releaseConfigurationLoad()
        let lent = try await borrow.value
        await restore.value

        XCTAssertEqual(appState.status, .signedIn)
        XCTAssertNotNil(lent)
        XCTAssertTrue(appState.client === lent)
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertEqual(count(of: "loadConfiguration cabalmail.example"), 1)
    }

    /// And the other way round: a borrow while the launch restore holds its
    /// load waits for the restore's build, and gets the session's client.
    func testABorrowWaitsForTheRestoresBuildInFlight() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.holdNextConfigurationLoad()
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        await SignInScript.awaitHeldLoad(in: harness)
        let manager = self.manager
        let borrow = Task { try await manager.borrowClient() }
        for _ in 0..<20 { await Task.yield() }

        harness.releaseConfigurationLoad()
        await restore.value
        let lent = try await borrow.value

        XCTAssertEqual(appState.status, .signedIn)
        XCTAssertTrue(appState.client === lent)
        XCTAssertEqual(harness.clients.count, 1)
    }

    /// A notification action on a cold background launch works through the
    /// stored account's client, which the restore then adopts.
    func testANotificationActionOnABackgroundLaunchBorrowsTheClientTheRestoreAdopts() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()

        await makeRegistrar().handleNotificationAction(identifier: "MARK_READ", ref: try Self.pushRef())
        let calls = await harness.imap.flagCalls
        XCTAssertEqual(calls.map(\.uids), [[4271]], "the action ran")
        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.clients.count, 1)
    }

    /// Signed out, with no stored tokens, there is nothing to lend and
    /// nothing is built.
    func testWithNoStoredSessionNothingIsLent() async throws {
        harness.seedLastSession()

        let lent = try await manager.borrowClient()

        XCTAssertNil(lent)
        XCTAssertEqual(harness.clients.count, 0)
    }

    // MARK: - Letting the lent client go

    /// Another account signs in while a client is lent: the lent client is
    /// shut down, and borrowers get the new session's.
    func testAnotherAccountsSignInLetsTheLentClientGo() async throws {
        harness.seedLastSession(username: "alice")
        try await harness.seedTokens()
        let borrowed = try await manager.borrowClient()
        let lent = try XCTUnwrap(borrowed)

        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-bob"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "bob", password: SignInScript.password
        )

        let wired = try XCTUnwrap(harness.appState.client)
        XCTAssertFalse(wired === lent)
        try await waitUntil { await lent.isShutDown }
        let now = try await manager.borrowClient()
        XCTAssertTrue(now === wired)
    }

    /// The restore validates an adopted client like one it built: a refused
    /// refresh takes the expiry arm, the lent client is shut down, and with
    /// the tokens gone borrowers get nothing.
    func testARestoreThatFindsTheSessionExpiredLetsTheLentClientGo() async throws {
        harness.seedLastSession()
        try await harness.seedTokens(expiresIn: -60)
        let borrowed = try await manager.borrowClient()
        let lent = try XCTUnwrap(borrowed)
        await harness.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "revoked"))

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.signedOutReason, .sessionExpired)
        try await waitUntil { await lent.isShutDown }
        let now = try await manager.borrowClient()
        XCTAssertNil(now)
        XCTAssertEqual(harness.clients.count, 1)
    }

    // MARK: - Helpers

    /// A push registrar over a silent notification center and a private
    /// defaults suite, borrowing from the harness's session manager.
    private func makeRegistrar() -> PushRegistrar {
        let registrar = PushRegistrar(
            notificationCenter: PushNotificationCenter(
                requestAuthorization: { _ in false },
                add: { _ in },
                removeAllDeliveredNotifications: {}
            ),
            defaults: defaults,
            enrichmentStore: PushEnrichmentStore(secureStore: nil, defaults: defaults)
        )
        registrar.attach(manager)
        return registrar
    }

    private static func pushRef() throws -> PushMessageRef {
        try XCTUnwrap(PushMessageRef(userInfo: ["msgRef": ["folder": "INBOX", "uid": 4271]]))
    }

    private func count(of event: String) -> Int {
        harness.events.filter { $0 == event }.count
    }
}
