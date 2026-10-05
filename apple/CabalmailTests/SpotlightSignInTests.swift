import XCTest
import CabalmailKit
@testable import Cabalmail

/// A Spotlight result tapped while signed out parks on `pendingSpotlightRef`
/// until a session is wired. The index holds the last signed-in account's
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

        let cursor = try XCTUnwrap(harness.appState.navCoordinator)
        try await waitUntilOnMainActor { cursor.navigateRequest != nil }
        XCTAssertEqual(cursor.navigateRequest?.folder, "Archive")
        XCTAssertEqual(cursor.navigateRequest?.uid, 4242)
        XCTAssertNil(harness.appState.pendingSpotlightRef)
    }

    func testAnotherAccountsSignInDropsTheParkedResult() async throws {
        await parkAResultAfterASignOut()

        await signIn(as: "bob")

        let cursor = try XCTUnwrap(harness.appState.navCoordinator)
        // A replay routes through a task of its own (the same-account test
        // above waits for it); give one every chance to land before checking
        // that none did.
        for _ in 0..<20 { await Task.yield() }
        _ = await harness.appState.client?.envelopeCache.snapshot(for: "Archive")
        XCTAssertNil(cursor.navigateRequest)
        XCTAssertNil(harness.appState.pendingSpotlightRef)
    }

    /// Alice signs in and out, then a result is tapped while signed out.
    private func parkAResultAfterASignOut() async {
        await signIn(as: "alice")
        await harness.appState.signOut()
        harness.appState.routeSpotlightRef(ref)
        XCTAssertEqual(harness.appState.pendingSpotlightRef, ref, "precondition: parked while signed out")
    }

    private func signIn(as username: String) async {
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: \(username) signed in")
    }
}
