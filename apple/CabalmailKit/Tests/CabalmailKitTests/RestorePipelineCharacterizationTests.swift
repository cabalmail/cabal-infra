import XCTest
@testable import CabalmailKit

/// Characterization suite for workstream 0.8 (the app-layer rearchitecture
/// that splits `AppState` into per-window navigation and a per-account
/// session). It pins the launch-time restore pipeline exactly as
/// `AppState.restoreIfPossible` chains it today, in the `do` block after
/// `status = .restoring`: `ConfigLoader.load(controlDomain:cache:)`, then
/// `CabalmailClient.make(...)` with the app's `SessionInvalidationMonitor`,
/// then `OfflineLaunch.validateStoredSession`. AppState has no seam for those
/// calls yet, so the Kit half of the chain is pinned here, with a scripted
/// network, a `ConfigurationCache` over a private defaults suite, an
/// in-memory keychain and a fresh cache directory per test.
///
/// Protects the offline launch (#1779), the refused-refresh mapping (#1288)
/// and its announcement (#1703). What AppState does with each outcome (which
/// keychain keys it clears, which status it lands on) is AppState's and is
/// not exercised here. A case that pins behaviour that looks wrong says so.
final class RestorePipelineCharacterizationTests: XCTestCase {
    private var harness: RestoreHarness!

    override func setUp() {
        super.setUp()
        harness = RestoreHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    func testFreshTokenRestoresWithOnlyTheConfigFetch() async throws {
        let fresh = RestoreHarness.tokens(id: "LIVE-ID", expiresIn: 3600)
        try harness.seed(fresh)
        let announcements = harness.monitor.events()

        let client = try await harness.restore()

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json"])
        XCTAssertEqual(try harness.storedTokens(), fresh)
        XCTAssertEqual(client.configuration.cognito.clientId, "clientX")
        XCTAssertEqual(
            harness.cache.load(controlDomain: RestoreHarness.domain), client.configuration,
            "a successful fetch during restore refreshes the cached config.json"
        )
        let token = try await client.authService.currentIdToken()
        XCTAssertEqual(token, "LIVE-ID")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    func testExpiredTokenRefreshesOnceAndPersistsTheNewPair() async throws {
        try harness.seed(RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600, refresh: "REFRESH-1"))
        let announcements = harness.monitor.events()

        try await harness.restore()

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json", "Cognito InitiateAuth REFRESH_TOKEN_AUTH"])
        let body = try await harness.network.body(ofRequest: 1)
        XCTAssertEqual((body["AuthParameters"] as? [String: String])?["REFRESH_TOKEN"], "REFRESH-1")
        XCTAssertEqual(body["ClientId"] as? String, "clientX", "the client id comes from the fetched config")
        let stored = try XCTUnwrap(try harness.storedTokens())
        XCTAssertEqual(stored.idToken, "NEW-ID")
        XCTAssertEqual(stored.accessToken, "NEW-ACCESS")
        XCTAssertEqual(stored.refreshToken, "REFRESH-1", "Cognito omits it on refresh; the stored one is reused")
        XCTAssertFalse(stored.isExpired())
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    /// #1779: no network, but an earlier launch cached `config.json`. The
    /// refresh never reaches Cognito, so validation passes on the keychain's
    /// expired tokens and the session is wired anyway.
    func testCachedConfigAndUnreachableCognitoStillRestore() async throws {
        let expired = RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600)
        try harness.seed(expired)
        let earlier = try await ConfigLoader.load(
            controlDomain: RestoreHarness.domain, transport: harness.network, cache: harness.cache
        )
        await harness.network.goOffline()
        let announcements = harness.monitor.events()

        let client = try await harness.restore()

        XCTAssertEqual(client.configuration, earlier)
        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json", "GET config.json", "Cognito InitiateAuth REFRESH_TOKEN_AUTH"])
        XCTAssertEqual(try harness.storedTokens(), expired, "an unreachable refresh changes nothing stored")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    func testOfflineWithNothingCachedThrowsNetworkBeforeAClientIsBuilt() async throws {
        let expired = RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600)
        try harness.seed(expired)
        await harness.network.goOffline()

        do {
            try await harness.restore()
            XCTFail("expected the config fetch to fail")
        } catch let error as CabalmailError {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        }

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json"], "Cognito is never asked")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.cacheRoot.path),
            "make() never ran, so nothing was created under the cache directory"
        )
        XCTAssertEqual(try harness.storedTokens(), expired)
    }

    /// #1288 and #1703: the refusal throws `.authExpired` and announces once.
    /// The Kit leaves the keychain alone; clearing it is AppState's catch.
    func testRefusedRefreshThrowsAuthExpiredAnnouncesOnceAndKeepsTheTokens() async throws {
        let expired = RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600)
        try harness.seed(expired)
        await harness.network.answerCognito(.refuses)
        let announcements = harness.monitor.events()

        do {
            try await harness.restore()
            XCTFail("expected the refused refresh to throw")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try harness.storedTokens(), expired)
        // AppState subscribes in `wireSession`, after this point. The monitor
        // keeps no replay (pinned in general by
        // SessionInvalidationMonitorCharacterizationTests), so that observer
        // never hears this refusal; this pins the consequence for restore.
        let lateObserver = harness.monitor.events()
        let late = await bufferedCount(lateObserver)
        XCTAssertEqual(late, 0)
    }

    func testMissingRefreshTokenThrowsAuthExpiredWithoutAskingCognito() async throws {
        let expired = RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600, refresh: nil)
        try harness.seed(expired)
        let announcements = harness.monitor.events()

        do {
            try await harness.restore()
            XCTFail("expected an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json"])
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1, "the no-refresh-token path announces like a refusal")
        XCTAssertEqual(try harness.storedTokens(), expired)
    }

    /// A corrupt or old-format token blob is removed and reads as no stored
    /// session: `currentIdToken` throws `.notSignedIn`, which AppState's
    /// restore shows as an expired session on the sign-in form, username
    /// kept (#1806). Before, the raw `DecodingError` escaped `OfflineLaunch`,
    /// AppState showed "The data couldn't be read ..." and kept the blob, so
    /// every launch ended the same way until an interactive sign-in, and a
    /// change to `AuthTokens`' `Codable` shape would have put every upgraded
    /// user there.
    func testCorruptTokenBlobIsClearedAndReadsAsNotSignedIn() async throws {
        let blob = Data("not a token pair".utf8)
        try harness.keychain.set(blob, forKey: SecureStoreKey.authTokens)
        let announcements = harness.monitor.events()

        do {
            try await harness.restore()
            XCTFail("expected restore to find no usable session")
        } catch CabalmailError.notSignedIn {
            // expected
        } catch {
            XCTFail("expected .notSignedIn, got \(error)")
        }

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json"])
        XCTAssertNil(try harness.keychain.get(SecureStoreKey.authTokens))
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)
    }

    /// Pins current behaviour, which looks like a defect: `OfflineLaunch`
    /// treats every `.transport` as "Cognito unreachable", and the keychain
    /// reports its own failures as `.transport`. So a refresh that reached
    /// Cognito and succeeded, but could not be saved, passes validation as
    /// if offline; the new pair is dropped and the next token read refreshes
    /// all over again. Counting `.transport` as unreachable is deliberate and
    /// older than `OfflineLaunch` (2028a6a1 moved it out of AppState), and
    /// dropping it would land restore on `.signedOut`; the root is the
    /// keychain reusing a wire-error case.
    /// Tracked in #1808.
    func testKeychainWriteFailureDuringASuccessfulRefreshStillPasses() async throws {
        let store = WriteFailingSecureStore()
        let expired = RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600)
        try harness.seed(expired, into: store.base)
        store.failWrites = true
        let announcements = harness.monitor.events()

        let client = try await harness.restore(store: store)

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["GET config.json", "Cognito InitiateAuth REFRESH_TOKEN_AUTH"])
        XCTAssertEqual(store.failedWrites, 1)
        XCTAssertEqual(try harness.storedTokens(in: store.base), expired, "the refreshed pair was lost")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0)

        store.failWrites = false
        let token = try await client.authService.currentIdToken()
        XCTAssertEqual(token, "NEW-ID")
        let after = await harness.network.trail
        XCTAssertEqual(after.filter { $0.hasPrefix("Cognito") }.count, 2, "the lost refresh is paid for twice")
    }
}

/// What happens on the client restore hands to `wireSession`: the first call
/// made after an offline launch, and the monitor `make()` threads through to
/// both the auth service and the API client.
final class RestoredSessionCharacterizationTests: XCTestCase {
    private var harness: RestoreHarness!

    override func setUp() {
        super.setUp()
        harness = RestoreHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    /// Builds the offline launch of #1779: config.json cached by an earlier
    /// launch, expired tokens, no network. Restore passes; the network then
    /// comes back with Cognito answering `cognito`.
    private func offlineRestore(thenCognito cognito: RestoreNetwork.CognitoAnswer) async throws -> CabalmailClient {
        try harness.seed(RestoreHarness.tokens(id: "OLD-ID", expiresIn: -3600))
        _ = try await ConfigLoader.load(
            controlDomain: RestoreHarness.domain, transport: harness.network, cache: harness.cache
        )
        await harness.network.goOffline()
        let client = try await harness.restore()
        await harness.network.goOnline(cognito: cognito)
        await harness.network.clearTrail()
        return client
    }

    func testFirstCallAfterAnOfflineRestoreRefreshesBeforeItIsSent() async throws {
        let client = try await offlineRestore(thenCognito: .refreshes)

        let addresses = try await client.apiClient.listAddresses()

        XCTAssertTrue(addresses.isEmpty)
        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["Cognito InitiateAuth REFRESH_TOKEN_AUTH", "API GET /prod/list"])
        let authorization = await harness.network.requests.last?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authorization, "NEW-ID")
        XCTAssertEqual(try harness.storedTokens()?.idToken, "NEW-ID")
    }

    /// The teardown signal for "launched offline, then the session turned
    /// out to be dead": the request dies minting its token, before it is
    /// sent, and the announcement reaches the monitor the app handed `make()`.
    func testRefusedRefreshAfterAnOfflineRestoreAnnouncesOnTheAppMonitor() async throws {
        let client = try await offlineRestore(thenCognito: .refuses)
        let announcements = harness.monitor.events()

        do {
            _ = try await client.apiClient.listAddresses()
            XCTFail("expected the refused refresh to throw")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let trail = await harness.network.trail
        XCTAssertEqual(trail, ["Cognito InitiateAuth REFRESH_TOKEN_AUTH"], "the API request is never sent")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1)
    }

    /// `make()` hands the same monitor to the API client, so a 401 that
    /// survives a successful refresh announces there too.
    func testRejectedReplayOnARestoredClientAnnouncesOnTheAppMonitor() async throws {
        try harness.seed(RestoreHarness.tokens(id: "LIVE-ID", expiresIn: 3600))
        let client = try await harness.restore()
        await harness.network.answerAPI([401, 401])
        await harness.network.clearTrail()
        let announcements = harness.monitor.events()

        do {
            _ = try await client.apiClient.listAddresses()
            XCTFail("expected the second 401 to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }

        let trail = await harness.network.trail
        XCTAssertEqual(trail, [
            "API GET /prod/list", "Cognito InitiateAuth REFRESH_TOKEN_AUTH", "API GET /prod/list",
        ])
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 1)
    }
}

// MARK: - Harness

/// One test's world: the scripted network, the config cache over a private
/// defaults suite, the keychain, the cache directory and the app's monitor.
private final class RestoreHarness {
    static let domain = "cabalmail.example"

    let network = RestoreNetwork()
    let suiteName = "RestorePipelineCharacterizationTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let cache: ConfigurationCache
    let keychain = InMemorySecureStore()
    let monitor = SessionInvalidationMonitor()
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("restore-pipeline-\(UUID().uuidString)")

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        cache = ConfigurationCache(defaults: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// The `do` block of `AppState.restoreIfPossible`, call for call, with
    /// the test's transport, cache, keychain and monitor in place of the
    /// app's. Returns the client restore would hand to `wireSession`.
    @discardableResult
    func restore(store: SecureStore? = nil) async throws -> CabalmailClient {
        let configuration = try await ConfigLoader.load(controlDomain: Self.domain, transport: network, cache: cache)
        let client = try CabalmailClient.make(
            configuration: configuration,
            secureStore: store ?? keychain,
            httpTransport: network,
            cacheDirectory: cacheRoot,
            sessionInvalidation: monitor
        )
        try await OfflineLaunch.validateStoredSession(client.authService)
        return client
    }

    static func tokens(id: String, expiresIn: TimeInterval, refresh: String? = "REFRESH") -> AuthTokens {
        AuthTokens(
            idToken: id,
            accessToken: "ACCESS-\(id)",
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Writes the pair the way `CognitoAuthService` persists it, as the
    /// keychain holds it when restore starts.
    func seed(_ tokens: AuthTokens, into store: SecureStore? = nil) throws {
        try (store ?? keychain).set(JSONEncoder().encode(tokens), forKey: SecureStoreKey.authTokens)
    }

    func storedTokens(in store: SecureStore? = nil) throws -> AuthTokens? {
        guard let data = try (store ?? keychain).get(SecureStoreKey.authTokens) else { return nil }
        return try JSONDecoder().decode(AuthTokens.self, from: data)
    }
}

/// The three hosts restore talks to: the control domain's `config.json`,
/// Cognito, and the API. Every request is recorded in order as a short label.
private actor RestoreNetwork: HTTPTransport {
    enum CognitoAnswer { case refreshes, refuses, unreachable }

    private static let configDocument = Data("""
    {
      "control_domain": "cabalmail.example",
      "domains": [{"domain": "cabalmail.example", "zone_id": "Z1", "name_servers": []}],
      "invokeUrl": "https://api.cabalmail.example/prod",
      "cognitoConfig": {"region": "us-east-1", "poolData": {"UserPoolId": "us-east-1_ABC", "ClientId": "clientX"}}
    }
    """.utf8)

    private static let refreshed = Data("""
    {"AuthenticationResult":{"IdToken":"NEW-ID","AccessToken":"NEW-ACCESS","ExpiresIn":3600,"TokenType":"Bearer"}}
    """.utf8)

    private static let refusal = Data("""
    {"__type":"com.amazonaws.cognito.identity.model#NotAuthorizedException","message":"Refresh Token has been revoked"}
    """.utf8)

    private static let offline = CabalmailError.network("The Internet connection appears to be offline.")

    private var configReachable = true
    private var cognito = CognitoAnswer.refreshes
    private var apiStatuses: [Int] = []
    private(set) var trail: [String] = []
    private(set) var requests: [URLRequest] = []

    func goOffline() { (configReachable, cognito) = (false, .unreachable) }
    func goOnline(cognito answer: CognitoAnswer) { (configReachable, cognito) = (true, answer) }
    func answerCognito(_ answer: CognitoAnswer) { cognito = answer }
    func answerAPI(_ statuses: [Int]) { apiStatuses = statuses }
    func clearTrail() { trail = [] }

    func body(ofRequest index: Int) throws -> sending [String: Any] {
        let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil, "no request \(index)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        switch url.host {
        case "cabalmail.example":
            trail.append("GET config.json")
            guard configReachable else { throw Self.offline }
            return (Self.configDocument, Self.response(url, 200))
        case "cognito-idp.us-east-1.amazonaws.com":
            trail.append(Self.cognitoLabel(request))
            switch cognito {
            case .refreshes: return (Self.refreshed, Self.response(url, 200))
            case .refuses: return (Self.refusal, Self.response(url, 400))
            case .unreachable: throw Self.offline
            }
        default:
            trail.append("API \(request.httpMethod ?? "GET") \(url.path)")
            let status = apiStatuses.isEmpty ? 200 : apiStatuses.removeFirst()
            return (Data((status == 200 ? "[]" : "unauthorized").utf8), Self.response(url, status))
        }
    }

    private static func cognitoLabel(_ request: URLRequest) -> String {
        let target = request.value(forHTTPHeaderField: "X-Amz-Target")?
            .replacingOccurrences(of: "AWSCognitoIdentityProviderService.", with: "") ?? "?"
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        let flow = body?["AuthFlow"] as? String
        return ["Cognito", target, flow].compactMap { $0 }.joined(separator: " ")
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// A keychain whose writes can be made to fail the way `KeychainSecureStore`
/// reports an OSStatus: as `.transport`.
private final class WriteFailingSecureStore: SecureStore, @unchecked Sendable {
    let base = InMemorySecureStore()
    private let lock = NSLock()
    private var failing = false
    private var failures = 0

    var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var failedWrites: Int { lock.withLock { failures } }

    func set(_ value: Data, forKey key: String) throws {
        let fail = lock.withLock { () -> Bool in
            if failing { failures += 1 }
            return failing
        }
        if fail { throw CabalmailError.transport("Keychain write failed (-25308)") }
        try base.set(value, forKey: key)
    }

    func get(_ key: String) throws -> Data? { try base.get(key) }
    func remove(_ key: String) throws { try base.remove(key) }
}
