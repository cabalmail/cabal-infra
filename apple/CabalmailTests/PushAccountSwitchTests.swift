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
/// A tap opens through the harness's own deep-link router; with no window
/// mounted it parks there, and a window landed on the session takes it.
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
        drive(harness, with: makeRegistrar(for: harness))
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

        XCTAssertNotNil(harness.appState.navCoordinator)
        XCTAssertNil(harness.appState.deepLinks.parked)
        XCTAssertEqual(center.removals, 2, "one at alice's sign-out, one as bob's session starts")
    }

    func testTheSameAccountKeepsATapParkedAfterASignOut() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        await signIn(harness, as: "alice")
        await harness.appState.signOut()
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        await signIn(harness, as: "alice")

        await assertOpened(harness)
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

        XCTAssertNotNil(harness.appState.navCoordinator)
        XCTAssertNil(harness.appState.deepLinks.parked)
    }

    /// The registrar's own two drops, with a router the app state does not
    /// share (in the app they share one, and `AppState` drops the link too):
    /// its session's end, and a session for another account than the last.
    func testTheRegistrarDropsAParkedTapByItsOwnRules() async throws {
        let world = try SessionHarness()
        extraHarnesses.append(world)
        let own = DeepLinkRouter()
        let registrar = PushRegistrar(
            notificationCenter: center.center, defaults: defaults,
            enrichmentStore: PushEnrichmentStore(secureStore: nil, defaults: defaults), deepLinks: own
        )
        drive(world, with: registrar)
        await signIn(world, as: "alice")
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)
        XCTAssertNotNil(own.parked, "precondition: no window of this router to take it")

        await world.appState.signOut()
        XCTAssertNil(own.parked, "the session's end")

        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)
        await signIn(world, as: "bob")
        XCTAssertNil(own.parked, "another account's session")
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
        await assertOpened(harness)
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
        let registrar = makeRegistrar(for: relaunched)
        drive(relaunched, with: registrar)
        await registrar.handleNotificationAction(identifier: "OPEN", ref: ref)

        await signIn(relaunched, as: "bob")

        XCTAssertNotNil(relaunched.appState.navCoordinator)
        XCTAssertNil(relaunched.appState.deepLinks.parked)
        XCTAssertEqual(center.removals, 1, "bob's session start removed alice's notifications")
    }

    // MARK: - Archive destination (#1882)

    /// Where earlier builds remembered the first archive folder they found,
    /// for every account after it: a case-insensitive match for "Archive" on
    /// the folder list, so a folder like `archive` listed ahead of Dovecot's
    /// `Archive` was the one kept.
    private static let legacyArchiveFolderKey = "cabalmail.push.archiveFolder"

    /// An earlier build's remembered folder (alice's `archive`) is in the
    /// defaults; bob signs in on the same device and archives from a
    /// notification. His message goes to Archive, the folder the in-app
    /// archive uses: nothing remembered from another account is consulted.
    func testArchiveAfterAnAccountSwitchMovesToTheNewAccountsArchive() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        registrar.attach(harness.appState.sessionManager)
        await signIn(harness, as: "alice")
        defaults.set("archive", forKey: Self.legacyArchiveFolderKey)
        await harness.appState.signOut()
        await signIn(harness, as: "bob")

        await registrar.handleNotificationAction(identifier: "ARCHIVE", ref: ref)

        let moves = await harness.imap.moveCalls
        XCTAssertEqual(moves.map(\.destination), ["Archive"])
        XCTAssertEqual(moves.map(\.folder), ["INBOX"])
        XCTAssertEqual(moves.map(\.uids), [[4271]])
        XCTAssertEqual(moves.map(\.markSeen), [true])
    }

    /// The same on a cold background launch, where nothing is wired and the
    /// action borrows the stored account's client: bob's Archive goes to
    /// Archive whatever an earlier account left in the defaults.
    func testArchiveOnABackgroundLaunchMovesToTheStoredAccountsArchive() async throws {
        let registrar = try XCTUnwrap(registrar(of: harness))
        registrar.attach(harness.appState.sessionManager)
        defaults.set("archive", forKey: Self.legacyArchiveFolderKey)
        harness.seedLastSession(username: "bob")
        try await harness.seedTokens()

        await registrar.handleNotificationAction(identifier: "ARCHIVE", ref: ref)

        let moves = await harness.imap.moveCalls
        XCTAssertEqual(moves.map(\.destination), ["Archive"])
        XCTAssertNotEqual(harness.appState.status, .signedIn, "precondition: no session was wired")
    }

    // MARK: - Helpers

    private var registrars: [ObjectIdentifier: PushRegistrar] = [:]

    private func makeRegistrar(for world: SessionHarness) -> PushRegistrar {
        PushRegistrar(
            notificationCenter: center.center,
            defaults: defaults,
            enrichmentStore: PushEnrichmentStore(secureStore: nil, defaults: defaults),
            deepLinks: world.appState.deepLinks
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

    /// The tap is waiting for a window, and the first window to land on
    /// the session opens it.
    private func assertOpened(_ world: SessionHarness, file: StaticString = #filePath, line: UInt = #line) async {
        guard case .message(let request)? = world.appState.deepLinks.parked else {
            return XCTFail("no tap is waiting", file: file, line: line)
        }
        XCTAssertEqual(request.folder, "INBOX", file: file, line: line)
        XCTAssertEqual(request.uid, 4271, file: file, line: line)
        XCTAssertEqual(request.messageID, "<m1@example.com>", file: file, line: line)

        let appState = world.appState
        let window = SceneNavigator(
            coordinator: { appState.navCoordinator }, hasClient: { true }, seed: .mail, deepLinks: appState.deepLinks
        )
        await window.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertNil(appState.deepLinks.parked, "the window took it", file: file, line: line)
        XCTAssertEqual(window.selectedFolder?.path, "INBOX", file: file, line: line)
        XCTAssertEqual(window.restores.pendingRestore?.uid, 4271, file: file, line: line)
        XCTAssertEqual(window.restores.pendingRestore?.messageID, "<m1@example.com>", file: file, line: line)
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
