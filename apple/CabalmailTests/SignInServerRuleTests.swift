import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The different-account rule looks at the server as well as the username
/// (#2560, account-isolation.md PR B). It is what clears another account's
/// cached mail when a session ended without its wipe: a launch whose refresh
/// was refused removes the tokens but keeps the cache and the remembered
/// server and username, and so does a force quit.
///
/// Comparing the username alone, the same username on another server opened
/// the last server's saved mail and sent its outbox through the new
/// session. The rule is `AccountIdentity`'s: the server trimmed, lowercased
/// and without a scheme, the username exact.
///
/// Every client the harness builds here sits over one set of caches and one
/// outbox, standing in for production's shared Application Support
/// directory.
@MainActor
final class SignInServerRuleTests: XCTestCase {
    private var world: SessionHarness!
    private var shared: SharedLocalData!
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("signin-server-rule-\(UUID().uuidString)")

    override func setUp() async throws {
        world = try SessionHarness()
        shared = try SharedLocalData(directory: scratch)
        shared.seat(clientsOf: world)
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
        shared = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Another server

    /// The path the rule exists for: alice's session on one server expires
    /// at launch, which keeps her cache, and then "alice" signs in on
    /// another server.
    func testTheSameUsernameOnAnotherServerAfterAnExpiredRestoreWipesTheCacheAndOutbox() async throws {
        try await expireAtLaunch(server: "cabalmail.example", username: "alice")
        let accountChanges = countAccountChanges()

        await signIn(server: "other.example", username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        try await shared.assertPresent(false)
        XCTAssertEqual(accountChanges.count, 1, "what was parked for the last account goes too")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), "other.example")
    }

    /// The same, without the restore: only the remembered pair and the
    /// cache are left, as after a force quit and a sign-in on the form.
    func testTheSameUsernameOnAnotherServerWipesTheCacheAndOutbox() async throws {
        world.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await shared.seed()

        await signIn(server: "other.example", username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        try await shared.assertPresent(false)
    }

    // MARK: - The same server

    /// The control: the same account signing back in after the expiry keeps
    /// its cache and its unsent mail.
    func testTheSameAccountAfterAnExpiredRestoreKeepsTheCacheAndOutbox() async throws {
        try await expireAtLaunch(server: "cabalmail.example", username: "alice")
        let accountChanges = countAccountChanges()

        await signIn(server: "cabalmail.example", username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        try await shared.assertPresent(true)
        XCTAssertEqual(accountChanges.count, 0)
    }

    /// The form remembers the server as typed, so the same server can come
    /// back with a scheme, spaces or capitals, in either direction. Too
    /// strict a rule here would delete the user's own unsent mail.
    func testTheSameServerRetypedKeepsTheCacheAndOutbox() async throws {
        let retyped = [
            ("cabalmail.example", " https://cabalmail.example "),
            ("cabalmail.example", "CabalMail.Example"),
            ("cabalmail.example", "http://cabalmail.example"),
            (" https://CabalMail.Example ", "cabalmail.example"),
        ]
        for (remembered, typed) in retyped {
            world.seedLastSession(controlDomain: remembered, username: "alice")
            try await shared.seed()
            let accountChanges = countAccountChanges()

            await signIn(server: typed, username: "alice")

            let label = "remembered \"\(remembered)\", typed \"\(typed)\""
            XCTAssertEqual(world.appState.status, .signedIn, label)
            try await shared.assertPresent(true, label)
            XCTAssertEqual(accountChanges.count, 0, label)
            await world.appState.signOut()
        }
    }

    // MARK: - The username

    /// The username half of the rule is unchanged: exact, so a username that
    /// differs only in case is another account on the same server.
    func testAUsernameThatDiffersOnlyInCaseOnTheSameServerStillWipes() async throws {
        world.seedLastSession(controlDomain: "cabalmail.example", username: "Alice")
        try await shared.seed()

        await signIn(server: "cabalmail.example", username: "alice")

        XCTAssertEqual(world.appState.status, .signedIn)
        try await shared.assertPresent(false)
    }

    // MARK: - Helpers

    /// A launch for the remembered account whose refresh Cognito refuses:
    /// signed out with a reason, the tokens gone, the pair and the cached
    /// mail still there.
    private func expireAtLaunch(server: String, username: String) async throws {
        world.seedLastSession(controlDomain: server, username: username)
        try await world.seedTokens(expiresIn: -60)
        try await shared.seed()
        await world.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "revoked"))

        await world.appState.restoreIfPossible()

        XCTAssertEqual(world.appState.status, .signedOut, "precondition")
        XCTAssertEqual(world.appState.signedOutReason, .sessionExpired, "precondition")
        XCTAssertFalse(world.hasStoredTokens, "precondition: the tokens are gone")
        XCTAssertEqual(world.defaults.string(forKey: SignInScript.domainKey), server, "precondition")
        try await shared.assertPresent(true, "precondition: the expiry keeps the cache")
    }

    private func signIn(server: String, username: String) async {
        await world.cognito.script(.passwordSignIn, .tokens(id: "ID-NEXT"))
        await world.appState.signIn(controlDomain: server, username: username, password: SignInScript.password)
    }

    /// Counts `SessionOwnerHooks.accountChanged` from here on, still running
    /// the app state's own.
    private func countAccountChanges() -> AccountChangeCount {
        let counter = AccountChangeCount()
        let accountChanged = world.appState.sessionManager.owner.accountChanged
        world.appState.sessionManager.owner.accountChanged = {
            counter.count += 1
            accountChanged()
        }
        return counter
    }
}

@MainActor
private final class AccountChangeCount {
    var count = 0
}

/// One envelope cache, body cache and outbox for every client the harness
/// builds: what a local wipe clears, and what the next account would
/// otherwise read and send.
@MainActor
private struct SharedLocalData {
    let mail: SignInCachedMail
    let outbox: Outbox

    init(directory: URL) throws {
        mail = try SignInCachedMail(directory: directory)
        outbox = try Outbox(directory: directory.appendingPathComponent("outbox"))
    }

    /// One cached INBOX message and one queued message.
    func seed() async throws {
        try await mail.seed()
        guard try await outbox.count() == 0 else { return }
        let sender = EmailAddress(name: nil, mailbox: "alice", host: "x.cabalmail.example")
        _ = try await outbox.enqueue(OutgoingMessage(from: sender, to: [sender], subject: "queued"))
    }

    func assertPresent(
        _ present: Bool, _ label: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        await mail.assertPresent(present, file: file, line: line)
        let queued = try await outbox.count()
        XCTAssertEqual(queued, present ? 1 : 0, "queued mail \(label)", file: file, line: line)
    }

    /// Has every client the environment builds from now on use these
    /// caches and this outbox (`SignInScript.seatClients`, with the outbox).
    func seat(clientsOf world: SessionHarness) {
        let build = world.appState.sessionManager.sessionEnvironment.makeClient
        let caches = mail
        let queue = outbox
        world.appState.sessionManager.sessionEnvironment.makeClient = { configuration, store, monitor, account in
            let built = try build(configuration, store, monitor, account)
            return CabalmailClient(
                configuration: built.configuration,
                authService: built.authService,
                apiClient: built.apiClient,
                imapClient: built.imapClient,
                addressCache: built.addressCache,
                envelopeCache: caches.envelopes,
                bodyCache: caches.bodies,
                draftStore: built.draftStore,
                outbox: queue,
                folderStateCache: built.folderStateCache
            )
        }
    }
}
