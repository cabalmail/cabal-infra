import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A notification's Mark as Read or Archive changes a folder behind the
/// message lists, so a running app's lists hard-reload at once rather than at
/// the next poll. That reload is the mail store's (`listRefreshTick`), not a
/// window command: sent while a request aimed at one window was still
/// undelivered, the untargeted refresh it used to send re-aimed that request
/// at every window (#1824).
@MainActor
final class PushActionReloadTests: XCTestCase {
    private var harness: SessionHarness!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "push-action-reload-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testANotificationActionReloadsEveryListAndLeavesAnAimedCommandAlone() async throws {
        let registrar = PushRegistrar(
            notificationCenter: PushNotificationCenter(
                requestAuthorization: { _ in false }, add: { _ in }, removeAllDeliveredNotifications: {}
            ),
            defaults: defaults,
            enrichmentStore: PushEnrichmentStore(secureStore: nil, defaults: defaults)
        )
        let appState = harness.appState
        appState.sessionManager.sessionEnvironment.hooks.sessionDidStart = { appState, client in
            registrar.sessionDidStart(appState: appState, client: client)
        }
        registrar.attach(appState.sessionManager)
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-bob"))
        await appState.signIn(controlDomain: SignInScript.domain, username: "bob", password: SignInScript.password)
        XCTAssertEqual(appState.status, .signedIn, "precondition: signed in")
        let ref = try XCTUnwrap(PushMessageRef(userInfo: ["msgRef": ["folder": "INBOX", "uid": 4271]]))
        let window = UUID()
        appState.requestCompose(in: window)

        await registrar.handleNotificationAction(identifier: "MARK_READ", ref: ref)
        await registrar.handleNotificationAction(identifier: "ARCHIVE", ref: ref)

        let flags = await harness.imap.flagCalls
        let moves = await harness.imap.moveCalls
        XCTAssertEqual(flags.count, 1, "precondition: Mark as Read reached the server")
        XCTAssertEqual(moves.count, 1, "precondition: Archive reached the server")
        XCTAssertEqual(appState.mailStore.listRefreshTick, 2, "each action asks the lists to reload once")
        XCTAssertTrue(appState.commandReaches(window))
        XCTAssertFalse(appState.commandReaches(UUID()), "the compose stays aimed at its own window")
    }
}
