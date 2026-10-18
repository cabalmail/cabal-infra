import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `SessionManager.isAdmin` across a real sign-in and sign-out, driven
/// through `SessionHarness` with scripted Cognito replies (auth parity plan,
/// C2). Settings lists Users from it, so it has to be right on the first
/// signed-in frame and gone with the session.
@MainActor
final class AdminSessionTests: XCTestCase {
    private var world: SessionHarness!

    override func setUp() async throws {
        world = try SessionHarness()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    private func signIn(idToken: String) async {
        await world.cognito.script(.passwordSignIn, .tokens(id: idToken))
        await world.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
    }

    func testAnAdminTokenMakesTheSessionAdminAndSignOutClearsIt() async {
        XCTAssertFalse(world.appState.isAdmin, "signed out")

        await signIn(idToken: TestFixtures.idToken(claims: ["cognito:username": "alice", "cognito:groups": ["admin"]]))
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertTrue(world.appState.isAdmin, "known by the time the session reads as signed in")

        await world.appState.signOut()
        XCTAssertFalse(world.appState.isAdmin)
    }

    func testATokenWithoutTheAdminGroupIsNotAdmin() async {
        await signIn(idToken: TestFixtures.idToken(claims: ["cognito:username": "alice", "cognito:groups": ["users"]]))
        XCTAssertEqual(world.appState.status, .signedIn)
        XCTAssertFalse(world.appState.isAdmin)
    }

    func testRereadingWithoutASessionLeavesItFalse() async {
        await world.appState.refreshAdminStatus()
        XCTAssertFalse(world.appState.isAdmin)
    }
}
