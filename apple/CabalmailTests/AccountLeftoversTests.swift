import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a different account's sign-in resets, and the same account's keeps
/// (account-isolation.md, PR C1): the per-install keys that name the last
/// account's folders and feeds, and the Debug Log. Sign Out leaves all of it
/// in place, so the same account finds its collapsed groups and its chosen
/// notification folders again.
@MainActor
final class AccountLeftoversTests: XCTestCase {
    private var world: SessionHarness!
    /// A line only this test logs, to find in the process-wide Debug Log.
    private var marker: String!

    override func setUp() async throws {
        world = try SessionHarness()
        marker = "account-leftovers-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    func testAnotherAccountsSignInResetsTheLeftovers() async {
        world.seedLastSession(username: "bob")
        seedLeftovers()

        await signIn(server: SignInScript.domain, username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        assertLeftovers(present: false)
    }

    /// Another server is another account (#2560).
    func testTheSameUsernameOnAnotherServerResetsTheLeftovers() async {
        world.seedLastSession(controlDomain: "other.example", username: "alice")
        seedLeftovers()

        await signIn(server: SignInScript.domain, username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        assertLeftovers(present: false)
    }

    func testTheSameAccountsSignInKeepsTheLeftovers() async {
        world.seedLastSession(username: "alice")
        seedLeftovers()

        await signIn(server: SignInScript.domain, username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        assertLeftovers(present: true)
    }

    func testTheSameServerRetypedKeepsTheLeftovers() async {
        world.seedLastSession(controlDomain: SignInScript.domain, username: "alice")
        seedLeftovers()

        await signIn(server: " https://CabalMail.Example ", username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        assertLeftovers(present: true)
    }

    /// A first sign-in on the install has no last account to differ from.
    func testAFirstSignInKeepsWhatIsThere() async {
        seedLeftovers()

        await signIn(server: SignInScript.domain, username: "alice")

        assertLeftovers(present: true)
    }

    func testSignOutKeepsTheLeftovers() async {
        await signIn(server: SignInScript.domain, username: "alice")
        seedLeftovers()

        await world.appState.signOut()

        assertLeftovers(present: true)
    }

    /// Only the chosen list goes: whether notifications are on, and the
    /// Inbox, All or Chosen scope, are the device's and stay.
    func testTheNotificationScopeAndSwitchStay() async {
        world.seedLastSession(username: "bob")
        seedLeftovers()
        world.defaults.set("custom", forKey: "cabalmail.push.folderScope")
        world.defaults.set(true, forKey: "cabalmail.push.userDisabled")

        await signIn(server: SignInScript.domain, username: "alice")

        XCTAssertNil(world.defaults.object(forKey: "cabalmail.push.chosenFolders"))
        XCTAssertEqual(world.defaults.string(forKey: "cabalmail.push.folderScope"), "custom")
        XCTAssertTrue(world.defaults.bool(forKey: "cabalmail.push.userDisabled"))
    }

    /// The keys, spelled out: these are what is on users' devices.
    func testTheKeysAreTheOnesTheViewsStore() {
        XCTAssertEqual(AccountLeftovers.defaultsKeys, [
            "cabalmail.folder.collapsedPaths",
            "cabalmail.feeds.collapsedFolders",
            "cabalmail.push.chosenFolders",
        ])
    }

    // MARK: - Helpers

    private func seedLeftovers() {
        world.defaults.set("Projects\nProjects/Cabal", forKey: "cabalmail.folder.collapsedPaths")
        world.defaults.set("folder-1", forKey: "cabalmail.feeds.collapsedFolders")
        world.defaults.set(["INBOX", "Projects"], forKey: "cabalmail.push.chosenFolders")
        CabalmailLog.info("AccountLeftoversTests", marker)
    }

    private func assertLeftovers(present: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for key in AccountLeftovers.defaultsKeys {
            XCTAssertEqual(world.defaults.object(forKey: key) != nil, present, key, file: file, line: line)
        }
        let logged = DebugLogStore.shared.snapshot().contains { $0.message == marker }
        XCTAssertEqual(logged, present, "the Debug Log", file: file, line: line)
    }

    private func signIn(server: String, username: String) async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await world.appState.signIn(controlDomain: server, username: username, password: SignInScript.password)
    }
}
