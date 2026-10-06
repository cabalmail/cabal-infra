import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The interleavings around a lent client (workstream 1.3) that a straight
/// borrow-then-restore doesn't reach: a build still running when a sign-in
/// wires a session or a sign-out ends one, a second-factor challenge
/// cancelled while its code is being checked, and an APNs token that lands
/// while a sign-out is under way. In each, a client the manager holds must
/// keep running, and one it no longer holds must not.
@MainActor
final class SessionLendingRaceTests: XCTestCase {
    private var harness: SessionHarness!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var scratch: URL!

    private var manager: SessionManager { harness.appState.sessionManager }

    override func setUp() async throws {
        harness = try SessionHarness()
        suiteName = "session-lending-race-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-lending-race-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A borrow builds the stored account's client while the user signs in.
    /// The sign-in wires its own client first, so the build finishes with a
    /// session wired: it is shut down rather than kept as a second client
    /// draining the outbox, and the borrower gets the session's.
    func testABuildThatFinishesAfterASignInIsLetGo() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.holdNextConfigurationLoad()
        let manager = self.manager
        let borrow = Task { try await manager.borrowClient() }
        await SignInScript.awaitHeldLoad(in: harness)

        await SignOutSuiteSteps.signIn(harness)
        let wired = try XCTUnwrap(harness.appState.client)
        harness.releaseConfigurationLoad()
        let lent = try await borrow.value

        XCTAssertTrue(lent === wired, "the borrower gets the session's client")
        XCTAssertEqual(harness.clients.count, 2)
        let built = try XCTUnwrap(harness.clients.last)
        XCTAssertFalse(built === wired)
        try await waitUntil { await built.isShutDown }
        let wiredIsShutDown = await wired.isShutDown
        XCTAssertFalse(wiredIsShutDown)
    }

    /// A build starts, a sign-out lands (signed out already, with the tokens
    /// kept, so it ends no session), and a restore starts and joins the
    /// build. The build is the restore's to wire: it must not have been shut
    /// down for the sign-out that came before the restore.
    func testARestoreThatJoinsABuildFromBeforeASignOutWiresALiveClient() async throws {
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.holdNextConfigurationLoad()
        let manager = self.manager
        let borrow = Task { try await manager.borrowClient() }
        await SignInScript.awaitHeldLoad(in: harness)
        await harness.appState.signOut()
        XCTAssertTrue(harness.hasStoredTokens, "precondition: a sign-out with no session keeps the tokens")
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        for _ in 0..<20 { await Task.yield() }

        harness.releaseConfigurationLoad()
        await restore.value
        let lent = try await borrow.value

        XCTAssertEqual(appState.status, .signedIn)
        let wired = try XCTUnwrap(appState.client)
        XCTAssertEqual(harness.clients.count, 1)
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let isShutDown = await wired.isShutDown
        XCTAssertFalse(isShutDown, "the restore wired a client its build had shut down")
        XCTAssertNil(lent, "the borrow that started before the sign-out lends nothing")
    }

    /// Two windows on the code form: one submits the code, the other
    /// cancels while Cognito checks it. The submit still signs in, as it did
    /// before the manager, and the client it wires must still be running.
    func testCancellingTheChallengeWhileItsCodeIsCheckedLeavesTheWiredClientRunning() async throws {
        let holding = HoldingTransport(inner: harness.cognito)
        installClients(over: holding)
        await harness.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "SESSION-1"))
        await harness.cognito.script(.mfaAnswer, .tokens(id: "ID-MFA"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .mfaCodeRequired(.totp))
        await holding.holdNext("RespondToAuthChallenge")
        let appState = harness.appState
        let submit = Task { await appState.submitMfaCode("123456") }
        await holding.awaitHeld()

        appState.cancelMfaChallenge()
        XCTAssertEqual(appState.status, .signedOut)
        await holding.release()
        await submit.value

        XCTAssertEqual(appState.status, .signedIn, "the submit in flight still signs in")
        let wired = try XCTUnwrap(appState.client)
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let isShutDown = await wired.isShutDown
        XCTAssertFalse(isShutDown, "the cancel shut down the client the submit wired")
    }

    /// The push registrar registers APNs tokens with the session's client
    /// only from `sessionDidStart` until `sessionWillEnd`. A token that
    /// arrives after `sessionWillEnd`, while the sign-out is still wiping
    /// the session and the manager still holds its client, parks for the
    /// next session instead of registering the account being signed out.
    func testATokenThatArrivesDuringASignOutParks() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let registrar = makeRegistrar()
        registrar.sessionDidStart(appState: harness.appState, client: try XCTUnwrap(harness.appState.client))
        registrar.deviceTokenDidChange("ab01")
        let cognito = harness.cognito
        try await waitUntil { await cognito.trail.contains { $0.hasSuffix("/push_register") } }

        await registrar.sessionWillEnd()
        XCTAssertNotNil(harness.appState.client, "precondition: the manager still holds the ending session's client")
        let before = await harness.cognito.trail.filter { $0.hasSuffix("/push_register") }.count
        registrar.deviceTokenDidChange("ab02")
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let after = await harness.cognito.trail.filter { $0.hasSuffix("/push_register") }.count
        XCTAssertEqual(after, before, "a token after sessionWillEnd registered the ending account")
    }

    // MARK: - Helpers

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

    /// Has every client the session builds talk through `transport`, the
    /// way the harness's own clients talk through its scripted Cognito.
    private func installClients(over transport: HTTPTransport) {
        let imap = harness.imap
        let scratch = self.scratch!
        harness.appState.sessionManager.sessionEnvironment.makeClient = { configuration, store, monitor in
            let auth = CognitoAuthService(
                configuration: configuration, transport: transport, secureStore: store, sessionInvalidation: monitor
            )
            let directory = scratch.appendingPathComponent(UUID().uuidString)
            return CabalmailClient(
                configuration: configuration,
                authService: auth,
                apiClient: URLSessionApiClient(
                    configuration: configuration, authService: auth, transport: transport, sessionInvalidation: monitor
                ),
                imapClient: imap,
                addressCache: AddressCache(),
                envelopeCache: try EnvelopeCache(directory: directory.appendingPathComponent("envelopes")),
                bodyCache: try MessageBodyCache(directory: directory.appendingPathComponent("bodies")),
                draftStore: try DraftStore(directory: directory.appendingPathComponent("drafts")),
                outbox: try Outbox(directory: directory.appendingPathComponent("outbox"))
            )
        }
    }
}

/// Passes requests through to `inner`, parking the next one aimed at a
/// named Cognito operation until `release()`.
private actor HoldingTransport: HTTPTransport {
    private let inner: HTTPTransport
    private var holdTarget: String?
    private var held: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    init(inner: HTTPTransport) {
        self.inner = inner
    }

    func holdNext(_ operation: String) {
        holdTarget = operation
    }

    /// Returns once a held request has arrived.
    func awaitHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let target = request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
        if let holdTarget, target.hasSuffix(holdTarget) {
            self.holdTarget = nil
            await withCheckedContinuation { continuation in
                held = continuation
                arrived?.resume()
                arrived = nil
            }
        }
        return try await inner.perform(request)
    }
}
