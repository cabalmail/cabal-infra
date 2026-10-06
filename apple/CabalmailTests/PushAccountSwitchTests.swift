import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A push notification names its message only by folder and UID, which mean
/// something only in the account it was delivered for. After a sign-out, the
/// old account's delivered notifications used to stay, their Mark as Read and
/// Archive acting on whatever message had that UID in the next account; and
/// a tap parked before a session was wired replayed into whichever account
/// signed in next (#1872). Now a sign-out drops the parked tap and the
/// delivered notifications, and a session for another account than the last
/// one drops whatever its predecessor left; the same account keeps its tap.
///
/// The registrar runs over a recording notification center and a private
/// defaults suite, never the host app's, and is driven from the harness's
/// session hooks the way `SessionHooks.live` drives `PushRegistrar.shared`.
@MainActor
final class PushAccountSwitchTests: XCTestCase {
    private var ref: PushMessageRef!
    private var harness: SessionHarness!
    private var center: RecordingNotificationCenter!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var extraHarnesses: [SessionHarness] = []

    override func setUp() async throws {
        ref = try XCTUnwrap(PushMessageRef(userInfo: [
            "msgRef": ["folder": "INBOX", "uid": 4271, "msg_id": "<m1@example.com>"],
        ]))
        suiteName = "push-account-switch-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        center = RecordingNotificationCenter()
        harness = try SessionHarness()
        drive(harness, with: makeRegistrar())
    }

    override func tearDown() async throws {
        for extra in extraHarnesses { await extra.tearDown() }
        extraHarnesses = []
        await harness?.tearDown()
        harness = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testASignOutRemovesTheDeliveredNotifications() async throws {
        await signIn(harness, as: "alice")
        XCTAssertEqual(center.removals, 0, "precondition: the first session starts with nothing to drop")

        await harness.appState.signOut()

        XCTAssertEqual(center.removals, 1)
    }

    func testAnotherAccountsSessionDropsATapParkedAfterASignOut() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        await signIn(harness, as: "alice")
        await harness.appState.signOut()
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        await signIn(harness, as: "bob")

        XCTAssertNil(try XCTUnwrap(harness.appState.navCoordinator).navigateRequest)
        XCTAssertEqual(center.removals, 2, "one at alice's sign-out, one as bob's session starts")
    }

    func testTheSameAccountKeepsATapParkedAfterASignOut() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        await signIn(harness, as: "alice")
        await harness.appState.signOut()
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        await signIn(harness, as: "alice")

        assertOpened(harness)
        XCTAssertEqual(center.removals, 1, "only alice's sign-out removed anything")
    }

    /// The launch restore builds the session while a tap waits for it, and
    /// the user signs out before it is wired: the restore ends the session it
    /// built (#1827), and the tap goes with it, so the next sign-in, even
    /// the same account's, opens nothing.
    func testASignOutDropsATapParkedBeforeIt() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        harness.seedLastSession(username: "alice")
        try await harness.seedTokens()
        let restore = await startHeldRestore()
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)
        let appState = harness.appState
        let signOut = Task { await appState.signOut() }
        try await waitUntilOnMainActor { appState.sessionManager.teardownGate.isTearingDown }
        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value
        XCTAssertEqual(center.removals, 1, "precondition: the unwired session's end ran the sign-out hook")

        await signIn(harness, as: "alice")

        XCTAssertNil(try XCTUnwrap(harness.appState.navCoordinator).navigateRequest)
    }

    /// A cold launch from a tap: the restore wires the account the tap was
    /// delivered for, and the tap opens. With no account remembered yet,
    /// which is how every install meets this change, nothing is dropped.
    func testATapParkedDuringTheLaunchRestoreOpensInTheRestoredAccount() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        harness.seedLastSession(username: "alice")
        try await harness.seedTokens()
        let restore = await startHeldRestore()
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        harness.releaseConfigurationLoad()
        await restore.value

        XCTAssertEqual(harness.appState.status, .signedIn)
        assertOpened(harness)
        XCTAssertEqual(center.removals, 0)
    }

    /// The last account outlives the process. Alice's session ended without
    /// a sign-out (a force quit, or a restore that found her session
    /// expired), so her notifications were never removed. In a new process,
    /// a tap on one parks, and bob signs in: the tap and the notifications go.
    func testANewProcessRemembersTheLastSessionsAccount() async throws {
        await signIn(harness, as: "alice")
        let relaunched = try SessionHarness()
        extraHarnesses.append(relaunched)
        let registrar = makeRegistrar()
        drive(relaunched, with: registrar)
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        await signIn(relaunched, as: "bob")

        XCTAssertNil(try XCTUnwrap(relaunched.appState.navCoordinator).navigateRequest)
        XCTAssertEqual(center.removals, 1, "bob's session start removed alice's notifications")
    }

    // MARK: - Helpers

    private var registrars: [ObjectIdentifier: PushRegistrar] = [:]

    private func makeRegistrar() -> PushRegistrar {
        PushRegistrar(
            notificationCenter: center.center,
            defaults: defaults,
            enrichmentStore: PushEnrichmentStore(secureStore: nil, defaults: defaults)
        )
    }

    private func registrar(of world: SessionHarness) -> PushRegistrar? {
        registrars[ObjectIdentifier(world)]
    }

    /// Points the harness's push hooks at `registrar`, where production's
    /// `SessionHooks.live` points them at `PushRegistrar.shared`; the
    /// harness's own recording of the hooks is not needed here.
    private func drive(_ world: SessionHarness, with registrar: PushRegistrar) {
        registrars[ObjectIdentifier(world)] = registrar
        world.appState.sessionManager.sessionEnvironment.hooks.sessionDidStart = { appState, client in
            registrar.sessionDidStart(appState: appState, client: client)
        }
        world.appState.sessionManager.sessionEnvironment.hooks.sessionWillEnd = {
            await registrar.sessionWillEnd()
        }
    }

    private func signIn(_ world: SessionHarness, as username: String) async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
        XCTAssertEqual(world.appState.status, .signedIn, "precondition: \(username) signed in")
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

    private func assertOpened(_ world: SessionHarness, file: StaticString = #filePath, line: UInt = #line) {
        let request = world.appState.navCoordinator?.navigateRequest
        XCTAssertEqual(request?.folder, "INBOX", file: file, line: line)
        XCTAssertEqual(request?.uid, 4271, file: file, line: line)
        XCTAssertEqual(request?.messageID, "<m1@example.com>", file: file, line: line)
    }
}

/// Records what the registrar asks of the notification center and answers a
/// permission request with "denied", so nothing registers for remote
/// notifications.
@MainActor
private final class RecordingNotificationCenter {
    private(set) var removals = 0

    var center: PushNotificationCenter {
        PushNotificationCenter(
            requestAuthorization: { _ in false },
            add: { _ in },
            removeAllDeliveredNotifications: { [weak self] in self?.removals += 1 }
        )
    }
}
