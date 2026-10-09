import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A main window's scene-stored route (`StoredRoute`): it reads back only for
/// the account it was stored for, and every sign-out tells each mounted
/// window to clear it (`AppState.accountForgottenTick`), while a failed launch
/// restore, which signs nobody out, leaves it.
@MainActor
final class StoredRouteTests: XCTestCase {
    private static let alice = StoredRoute.Account(controlDomain: "cabalmail.example", username: "alice")

    private var route: AppRoute {
        var route = AppRoute(section: .feeds)
        route.mail = AppRoute.Mail(
            folderPath: "Lists", message: MessageRef(folder: "Lists", uid: 7, messageId: "<seven@example.com>")
        )
        route.feeds = AppRoute.Feeds(scope: .subscription("s"))
        route.feeds.item = AppRoute.Item(RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k"))
        return route
    }

    // MARK: The codec

    func testARouteRoundTripsForItsAccount() throws {
        let data = try XCTUnwrap(StoredRoute.data(route, for: Self.alice))

        let decoded = try XCTUnwrap(StoredRoute.route(in: data, for: Self.alice))

        XCTAssertEqual(decoded, route)
        XCTAssertEqual(decoded.mail.message?.messageId, "<seven@example.com>")
        XCTAssertEqual(decoded.feeds.item?.sortKey, "k")
    }

    /// The brief's case: a window restored after another account signed in
    /// starts afresh rather than on the other account's folder.
    func testARouteStoredForAnotherAccountIsIgnored() {
        let data = StoredRoute.data(route, for: Self.alice)

        let otherUser = StoredRoute.Account(controlDomain: "cabalmail.example", username: "bob")
        let otherDomain = StoredRoute.Account(controlDomain: "mail.example.org", username: "alice")
        XCTAssertNil(StoredRoute.route(in: data, for: otherUser))
        XCTAssertNil(StoredRoute.route(in: data, for: otherDomain))
    }

    /// The open message is stored by the fields the resume session keeps,
    /// never a UIDVALIDITY, which only the list that knows its folder's may
    /// pair with a UID (#1873).
    func testTheStoredMessageCarriesNoUIDValidity() throws {
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(
            folderPath: "Lists", message: MessageRef(folder: "Lists", uid: 7, uidValidity: 77, messageId: "<7@x>")
        )
        let data = try XCTUnwrap(StoredRoute.data(route, for: Self.alice))

        XCTAssertFalse(try XCTUnwrap(String(bytes: data, encoding: .utf8)).contains("77"))
        let message = try XCTUnwrap(StoredRoute.route(in: data, for: Self.alice)?.mail.message)
        XCTAssertEqual(message, MessageRef(folder: "Lists", uid: 7))
        XCTAssertNil(message.uidValidity)
        XCTAssertEqual(message.messageId, "<7@x>")
    }

    func testNothingOrUnreadableDataIsIgnored() {
        XCTAssertNil(StoredRoute.route(in: nil, for: Self.alice))
        XCTAssertNil(StoredRoute.route(in: Data("not json".utf8), for: Self.alice))
        XCTAssertNil(StoredRoute.route(in: Data("{}".utf8), for: Self.alice))
    }

    /// A field a later build adds is ignored by this one, so a window stored
    /// by a newer build still restores after a downgrade.
    func testAnUnknownFieldIsIgnored() throws {
        let data = try XCTUnwrap(StoredRoute.data(route, for: Self.alice))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["listAnchor"] = ["folderPath": "Lists", "index": 3]
        let extended = try JSONSerialization.data(withJSONObject: object)

        XCTAssertEqual(StoredRoute.route(in: extended, for: Self.alice), route)
    }

    // MARK: Sign-out

    private var harness: SessionHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func signedIn() async throws -> SessionHarness {
        let harness = try SessionHarness()
        self.harness = harness
        harness.seedLastSession()
        try await harness.seedTokens()
        await harness.appState.restoreIfPossible()
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition")
        return harness
    }

    func testASignOutTellsEveryWindowToClearItsRoute() async throws {
        let harness = try await signedIn()
        let before = harness.appState.accountForgottenTick

        await harness.appState.signOut()

        XCTAssertEqual(harness.appState.accountForgottenTick, before + 1)
    }

    func testAnExpiryTellsEveryWindowToClearItsRoute() async throws {
        let harness = try await signedIn()
        let before = harness.appState.accountForgottenTick

        await harness.appState.sessionManager.handleSessionExpiry()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.accountForgottenTick, before + 1)
    }

    /// #1827: a sign-out while the launch restore runs (the Mac's Settings
    /// window is its own scene) goes from `.restoring` to `.signedOut`; the
    /// main window, on the splash, still clears its route.
    func testASignOutDuringTheLaunchRestoreTellsEveryWindowToClearItsRoute() async throws {
        let harness = try SessionHarness()
        self.harness = harness
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.holdNextConfigurationLoad()
        let appState = harness.appState
        let restore = Task { await appState.restoreIfPossible() }
        await harness.awaitConfigurationLoad()
        let signOut = Task { await appState.signOut() }
        try await waitUntilOnMainActor { appState.sessionManager.teardownGate.isTearingDown }

        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value

        XCTAssertEqual(appState.status, .signedOut)
        XCTAssertEqual(appState.accountForgottenTick, 1)
    }

    /// A launch restore that fails signs nobody out, so a window keeps its
    /// route for the sign-in that follows, as the resume session is kept.
    func testAFailedRestoreLeavesTheRoutes() async throws {
        let harness = try SessionHarness()
        self.harness = harness
        harness.seedLastSession()
        try await harness.seedTokens()
        harness.configurationResult = .failure(CabalmailError.network("offline"))

        await harness.appState.restoreIfPossible()

        XCTAssertNotEqual(harness.appState.status, .signedIn, "precondition: the restore failed")
        XCTAssertEqual(harness.appState.accountForgottenTick, 0)
    }
}
