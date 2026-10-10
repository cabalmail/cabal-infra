import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A Spotlight result tapped while signed out parks in the deep-link router
/// until a session is wired and a window lands on it. The index holds the last signed-in account's
/// mail, so the ref belongs to that account: the same account signing back
/// in opens it, and another account's sign-in drops it rather than open a
/// folder and UID that mean nothing in its mailbox (#1825).
@MainActor
final class SpotlightSignInTests: XCTestCase {
    private let ref = SpotlightMessageRef(folder: "Archive", uid: 4242)
    private var harness: SessionHarness!

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    func testTheSameAccountSigningBackInOpensTheParkedResult() async throws {
        await parkAResultAfterASignOut()

        await signIn(as: "alice")

        let appState = harness.appState
        let window = SceneNavigator(
            coordinator: { appState.navCoordinator }, hasClient: { true }, seed: .mail, deepLinks: appState.deepLinks
        )
        await window.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(window.selectedFolder?.path, "Archive")
        XCTAssertEqual(window.restores.pendingRestore?.uid, 4242)
        XCTAssertNil(appState.deepLinks.parked)
    }

    func testAnotherAccountsSignInDropsTheParkedResult() async throws {
        await parkAResultAfterASignOut()

        await signIn(as: "bob")

        XCTAssertNotNil(harness.appState.navCoordinator)
        // Give any stray route every chance to land before checking that
        // none did.
        for _ in 0..<20 { await Task.yield() }
        _ = await harness.appState.client?.envelopeCache.snapshot(for: "Archive")
        XCTAssertNil(harness.appState.deepLinks.parked)
    }

    /// Alice signs in and out, then a result is tapped while signed out.
    private func parkAResultAfterASignOut() async {
        await signIn(as: "alice")
        await harness.appState.signOut()
        harness.appState.routeSpotlightRef(ref)
        XCTAssertEqual(harness.appState.deepLinks.parked, .spotlight(ref), "precondition: parked while signed out")
    }

    private func signIn(as username: String) async {
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: \(username) signed in")
    }
}
