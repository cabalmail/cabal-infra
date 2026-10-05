import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One test's world for `AppState`'s session lifecycle (sign-in, MFA,
/// restore, sign-out), driven through its `SessionEnvironment` seam for the
/// workstream 0.8 characterization suites. Nothing here reaches the network,
/// the keychain, Application Support, the host app's `UserDefaults.standard`
/// or an OS permission prompt:
///
/// - configuration loads answer from `configurationResult`, and can be held
///   to observe the in-between states (`.signingIn`, `.restoring`);
/// - the secure store is in memory;
/// - clients are memberwise, over a `ScriptedCognito` transport for auth and
///   the API, a `FakeImapClient`, and caches in a temp directory;
/// - the last session persists in a private `UserDefaults` suite;
/// - every platform hook (push, Intents, watch, badge and contacts
///   permission) only records itself in `events`, in order, with whether
///   the session's tokens were still stored when it ran.
///
/// Call `tearDown()` from the test's tearDown: it signs out (stopping the
/// pollers and the session observer) and removes the suite and temp files.
@MainActor
final class SessionHarness {
    let appState = AppState()
    let cognito = ScriptedCognito()
    let imap = FakeImapClient()
    let secureStore = InMemorySecureStore()
    let configuration = TestFixtures.makeConfiguration()
    let defaults: UserDefaults

    /// What the environment and its hooks were asked to do, in order.
    private(set) var events: [String] = []
    /// Every client the environment built, oldest first.
    private(set) var clients: [CabalmailClient] = []
    /// The answer to every configuration load.
    var configurationResult: Result<Configuration, Error>
    /// When set, building a client throws this instead.
    var makeClientFailure: Error?

    private let suiteName = "session-harness-\(UUID().uuidString)"
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-harness-\(UUID().uuidString)")
    private var holdNextLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var loadArrived: CheckedContinuation<Void, Never>?

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        configurationResult = .success(configuration)
        appState.sessionEnvironment = environment()
    }

    func tearDown() async {
        releaseConfigurationLoad()
        await appState.signOut()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Seeding

    /// The control domain and username a previous launch left behind.
    func seedLastSession(controlDomain: String = "cabalmail.example", username: String = "alice") {
        defaults.set(controlDomain, forKey: "cabalmail.controlDomain")
        defaults.set(username, forKey: "cabalmail.lastUsername")
    }

    /// Stored Cognito tokens, in the format the auth service persists.
    func seedTokens(id: String = "ID-1", expiresIn: TimeInterval = 3600, refresh: String? = "REFRESH") async throws {
        let auth = CognitoAuthService(configuration: configuration, transport: cognito, secureStore: secureStore)
        try await auth.adopt(tokens: AuthTokens(
            idToken: id,
            accessToken: "access-\(id)",
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        ))
    }

    var hasStoredTokens: Bool {
        (try? secureStore.get(SecureStoreKey.authTokens)) != nil
    }

    // MARK: Holding the configuration load

    /// Parks the next configuration load until `releaseConfigurationLoad()`.
    func holdNextConfigurationLoad() {
        holdNextLoad = true
    }

    /// Returns once a held configuration load has arrived.
    func awaitConfigurationLoad() async {
        guard heldLoad == nil else { return }
        await withCheckedContinuation { loadArrived = $0 }
    }

    func releaseConfigurationLoad() {
        heldLoad?.resume()
        heldLoad = nil
    }

    private func parkIfHeld() async {
        guard holdNextLoad else { return }
        holdNextLoad = false
        await withCheckedContinuation { continuation in
            heldLoad = continuation
            loadArrived?.resume()
            loadArrived = nil
        }
    }

    // MARK: The environment

    private func record(_ event: String) {
        events.append(event)
    }

    private func environment() -> SessionEnvironment {
        SessionEnvironment(
            loadConfiguration: { [weak self] domain in
                guard let self else { throw CabalmailError.notConfigured }
                record("loadConfiguration \(domain)")
                await parkIfHeld()
                return try configurationResult.get()
            },
            makeSecureStore: { [weak self] in
                self?.record("makeSecureStore")
                return self?.secureStore ?? InMemorySecureStore()
            },
            makeClient: { [weak self] configuration, store, monitor in
                guard let self else { throw CabalmailError.notConfigured }
                record("makeClient")
                if let makeClientFailure { throw makeClientFailure }
                let client = try makeClient(configuration: configuration, store: store, monitor: monitor)
                clients.append(client)
                return client
            },
            makeNavCoordinator: { [weak self] client in
                NavStateCoordinator(
                    client: client,
                    clientID: "session-harness",
                    store: ResumeSessionStore(defaults: self?.defaults ?? .standard)
                )
            },
            lastSessionDefaults: defaults,
            publishControlDomain: { [weak self] in self?.record("publishControlDomain \($0)") },
            hooks: hooks()
        )
    }

    private func hooks() -> SessionHooks {
        SessionHooks(
            sessionDidStart: { [weak self] _, _ in self?.recordWithTokens("sessionDidStart") },
            sessionWillEnd: { [weak self] in self?.recordWithTokens("sessionWillEnd") },
            sessionDidEnd: { [weak self] in self?.recordWithTokens("sessionDidEnd") },
            pushSessionToWatch: { [weak self] _, _, username in self?.record("pushSessionToWatch \(username)") },
            requestBadgeAuthorization: { [weak self] in self?.record("requestBadgeAuthorization") },
            requestContactsAccess: { [weak self] _ in self?.record("requestContactsAccess") }
        )
    }

    private func recordWithTokens(_ event: String) {
        record("\(event) tokens=\(hasStoredTokens ? "stored" : "gone")")
    }

    private func makeClient(
        configuration: Configuration,
        store: SecureStore,
        monitor: SessionInvalidationMonitor
    ) throws -> CabalmailClient {
        let auth = CognitoAuthService(
            configuration: configuration, transport: cognito, secureStore: store, sessionInvalidation: monitor
        )
        let directory = root.appendingPathComponent(UUID().uuidString)
        return CabalmailClient(
            configuration: configuration,
            authService: auth,
            apiClient: URLSessionApiClient(
                configuration: configuration, authService: auth, transport: cognito, sessionInvalidation: monitor
            ),
            imapClient: imap,
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: directory.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: directory.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: directory.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: directory.appendingPathComponent("outbox"))
        )
    }
}
