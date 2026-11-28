import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Whose client the session lifecycle builds
/// (`docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.1). A client keeps its
/// saved mail in its account's own directory, so every place that builds one
/// has to say which account it is for: the server and username typed at a
/// sign-in, the remembered ones at a restore or for a client lent to
/// background work. And a sign-in that does not finish must not leave a
/// directory behind for an account that never signed in.
@MainActor
final class SessionClientAccountTests: XCTestCase {
    private var harness: SessionHarness!
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-client-account-\(UUID().uuidString)")

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Which account

    /// The server goes in as typed and is compared normalized; the username
    /// is the one typed, capitals included.
    func testASignInBuildsItsClientForTheServerAndUsernameTyped() async {
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-1"))

        await harness.appState.signIn(
            controlDomain: " https://CabalMail.Example ", username: "Alice", password: SignInScript.password
        )

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.clientAccounts, [Self.account("cabalmail.example", "Alice")])
        XCTAssertNotEqual(
            harness.clientAccounts, [Self.account("cabalmail.example", "alice")],
            "a username that differs only by case is another account"
        )
    }

    func testARestoreBuildsItsClientForTheRememberedAccount() async throws {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await harness.seedTokens()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.clientAccounts, [Self.account("cabalmail.example", "alice")])
    }

    /// A background launch with no session: the client lent to a
    /// notification action or an App Intent is the stored account's.
    func testALentClientIsBuiltForTheRememberedAccount() async throws {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await harness.seedTokens()

        let lent = try await harness.appState.sessionManager.borrowClient()

        XCTAssertNotNil(lent)
        XCTAssertEqual(harness.clientAccounts, [Self.account("cabalmail.example", "alice")])
    }

    // MARK: - A sign-in that does not finish

    /// A mistyped username is an account that never signs in. Its client
    /// made a directory for it; the refusal takes the directory away again.
    func testARefusedSignInRemovesTheDirectoryItsClientMade() async throws {
        seatFactoryClients()
        let typo = try XCTUnwrap(Self.account(SignInScript.domain, "alcie"))
        await harness.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "alcie", password: SignInScript.password
        )

        XCTAssertNotEqual(harness.appState.status, .signedIn)
        let home = AccountDirectory.url(for: typo, in: scratch)
        // The client is let go in a task of its own.
        try await waitUntilOnMainActor { !FileManager.default.fileExists(atPath: home.path) }
    }

    /// The same for a wrong password on an account that has been here
    /// before: its directory was already there, and it stays.
    func testARefusedSignInLeavesADirectoryThatWasAlreadyThere() async throws {
        seatFactoryClients()
        let alice = try XCTUnwrap(Self.account(SignInScript.domain, "alice"))
        let home = AccountDirectory.url(for: alice, in: scratch)
        let kept = home.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: kept)
        await harness.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )

        XCTAssertNotEqual(harness.appState.status, .signedIn)
        let refused = try XCTUnwrap(factoryClients.first)
        try await waitUntilOnMainActor { await refused.isShutDown }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    /// Backing out of the second-factor prompt abandons the sign-in too.
    func testCancellingTheSecondFactorPromptRemovesTheDirectoryItsClientMade() async throws {
        seatFactoryClients()
        let alice = try XCTUnwrap(Self.account(SignInScript.domain, "alice"))
        let home = AccountDirectory.url(for: alice, in: scratch)
        await harness.cognito.script(.passwordSignIn, .challenge(name: "SOFTWARE_TOKEN_MFA", session: "SESSION-1"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .mfaCodeRequired(.totp), "precondition")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path), "precondition: the parked client made it")

        harness.appState.sessionManager.cancelMfaChallenge()

        XCTAssertEqual(harness.appState.status, .signedOut)
        try await waitUntilOnMainActor { !FileManager.default.fileExists(atPath: home.path) }
    }

    // MARK: - Another account's directory (PR 1.2)

    /// Alice is the remembered account and her session ended without its
    /// wipe, so her directory is still there. A sign-in as Bob that is
    /// refused must not take it: the typed name may be a typo of hers.
    func testARefusedSignInAsAnotherAccountLeavesTheRememberedAccountsDirectory() async throws {
        seatFactoryClients()
        seatLaunchStep()
        let kept = try leaveTheRememberedAccountsDirectory()
        let bob = try XCTUnwrap(Self.account(SignInScript.domain, "bob"))
        await harness.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "bob", password: SignInScript.password
        )

        XCTAssertNotEqual(harness.appState.status, .signedIn)
        let refused = try XCTUnwrap(factoryClients.first)
        try await waitUntilOnMainActor { await refused.isShutDown }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        let made = AccountDirectory.url(for: bob, in: scratch)
        try await waitUntilOnMainActor { !FileManager.default.fileExists(atPath: made.path) }
    }

    /// Once Bob's sign-in has succeeded, Alice's directory goes: nothing
    /// else would ever remove it, and Bob's client never opens it.
    func testASignInAsAnotherAccountRemovesTheLastAccountsDirectoryOnceItSucceeds() async throws {
        seatFactoryClients()
        seatLaunchStep()
        let kept = try leaveTheRememberedAccountsDirectory()
        let bob = try XCTUnwrap(Self.account(SignInScript.domain, "bob"))
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-1"))

        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "bob", password: SignInScript.password
        )

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.deletingLastPathComponent().path))
        let accounts = scratch.appendingPathComponent(AccountDirectory.containerName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: accounts.path), [bob.directoryName])
    }

    // MARK: - Helpers

    /// Remembers alice and leaves her a directory with a file in it, as a
    /// session that ended without its wipe does. Returns the file.
    private func leaveTheRememberedAccountsDirectory() throws -> URL {
        harness.seedLastSession(controlDomain: SignInScript.domain, username: "alice")
        let alice = try XCTUnwrap(Self.account(SignInScript.domain, "alice"))
        let home = AccountDirectory.url(for: alice, in: scratch)
        let kept = home.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: kept)
        return kept
    }

    /// Has the environment run the launch step the app runs, over the cache
    /// root in `scratch`. Not part of `seatFactoryClients()`: with nobody
    /// remembered the step removes every account directory, and the tests
    /// above it start from one that is already there.
    private func seatLaunchStep() {
        let root = scratch
        harness.appState.sessionManager.sessionEnvironment.prepareAccountStorage = { remembered in
            await AccountDirectory.prepareAtLaunch(root: root, remembered: remembered)
        }
    }

    /// The clients `seatFactoryClients()` built, oldest first.
    private var factoryClients: [CabalmailClient] = []

    private static func account(_ controlDomain: String, _ username: String) -> AccountIdentity? {
        AccountIdentity(controlDomain: controlDomain, username: username)
    }

    /// Has the environment build its clients with the factory the app uses,
    /// over the harness's Cognito and a cache root in `scratch`, so a client
    /// has an account directory to make. Only for sign-ins that wire no
    /// session: the harness's own clients answer mail from a fake, and
    /// these would ask the scripted transport.
    private func seatFactoryClients() {
        let transport = harness.cognito
        let root = scratch
        let index = FakeSearchableIndex()
        let manager = harness.appState.sessionManager
        manager.sessionEnvironment.makeClient = { [weak self] configuration, store, monitor, account in
            let client = try CabalmailClient.make(
                configuration: configuration,
                secureStore: store,
                httpTransport: transport,
                cacheDirectory: root,
                account: account,
                sessionInvalidation: monitor,
                searchableIndex: index
            )
            self?.factoryClients.append(client)
            return client
        }
    }
}
