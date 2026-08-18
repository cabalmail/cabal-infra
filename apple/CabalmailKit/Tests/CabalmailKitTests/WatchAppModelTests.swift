import Foundation
import XCTest
@testable import CabalmailKit

// MARK: - Doubles

/// Path-routed HTTP double. Order-independent by construction: the model
/// fires background refreshes from `apply` and `createAddress`, so a FIFO
/// queue of responses would make assertions depend on task scheduling.
private actor RoutingTransport: HTTPTransport {
    private let routes: [String: (Data, Int)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (Data, Int)]) {
        self.routes = routes
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let match = routes.first(where: { path.hasSuffix($0.key) })?.value else {
            throw CabalmailError.transport("RoutingTransport has no route for \(path)")
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: match.1,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (match.0, response)
    }

    func bodies(forPathSuffix suffix: String) -> [Data] {
        requests
            .filter { ($0.url?.path ?? "").hasSuffix(suffix) }
            .compactMap { $0.httpBody }
    }
}

/// Records the usernames `WatchAppModel.apply` adopts, from whatever task the
/// model runs the adopt step on.
private actor AdoptRecorder {
    private(set) var usernames: [String] = []

    func record(_ username: String) {
        usernames.append(username)
    }
}

/// What `makeRestoredModel` hands back: the model plus the doubles a test
/// needs to assert against.
private struct WatchModelFixture {
    let model: WatchAppModel
    let transport: RoutingTransport
    let store: InMemorySecureStore
    let defaults: UserDefaults
}

// MARK: - Fixtures

private let testConfiguration = Configuration(
    controlDomain: "cabalmail.example",
    domains: [MailDomain(domain: "cabalmail.com"), MailDomain(domain: "cabalmail.net")],
    invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
    cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
)

/// Three rows the model must reorder: `Zeta` is favorited, the others are not,
/// and the set is mixed-case so the case-insensitive tiebreak shows.
private let testListBody = Data("""
{"Items":[
  {"address":"alpha@a1.cabalmail.com","subdomain":"a1","tld":"cabalmail.com"},
  {"address":"Zeta@z9.cabalmail.com","subdomain":"z9","tld":"cabalmail.com","favorite":true},
  {"address":"Beta@b2.cabalmail.net","subdomain":"b2","tld":"cabalmail.net"}
]}
""".utf8)

private let configurationDefaultsKey = "cabalmail.watch.configuration"

private func addresses(in phase: WatchAppModel.Phase) -> [Address]? {
    guard case .ready(let addresses) = phase else { return nil }
    return addresses
}

private func isLoading(_ phase: WatchAppModel.Phase) -> Bool {
    if case .loading = phase { return true }
    return false
}

/// Behaviour of the watch app's root model (#1124).
///
/// The model used to live in the `CabalmailWatch` app target, where no test
/// bundle could reach it: `swift test` sees only the package, and neither the
/// macOS nor the iOS host compiles watchOS-only sources. It now lives in the
/// Kit, so these run on the plain `swift test` host with no simulator.
///
/// Everything is driven through `URLSessionApiClient` over a routed HTTP
/// double, the same way the other API-level suites work — the model holds an
/// `any ApiClient`, so faking at the transport keeps the real request/response
/// coding in the loop.
final class WatchAppModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "cabalmail.watch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A model already holding a live (faked) session, as if a hand-off had
    /// been adopted: configuration in defaults, tokens in the secure store.
    /// `start()` restores from exactly that state, which is also what the
    /// shipping app does on every launch after the first pairing.
    @MainActor
    private func makeRestoredModel(routes: [String: (Data, Int)]) async throws -> WatchModelFixture {
        let transport = RoutingTransport(routes)
        let store = InMemorySecureStore()
        let defaults = makeDefaults()
        try store.set(Data("{}".utf8), forKey: SecureStoreKey.authTokens)
        defaults.set(try JSONEncoder().encode(testConfiguration), forKey: configurationDefaultsKey)
        let model = WatchAppModel(secureStore: store, defaults: defaults) { configuration, _ in
            WatchSession(
                apiClient: URLSessionApiClient(
                    configuration: configuration,
                    authService: StubAuthService(),
                    transport: transport
                ),
                adopt: { _, _ in }
            )
        }
        model.start()
        // `start()` restores the session and kicks off its address load on a
        // detached task. Drain it here so each test begins from a settled
        // list — otherwise that load can land in the middle of the call under
        // test and quietly re-seed the phase.
        for _ in 0..<500 where await transport.requests.isEmpty || isLoading(model.phase) {
            await Task.yield()
        }
        return WatchModelFixture(model: model, transport: transport, store: store, defaults: defaults)
    }

    // MARK: - Address list

    @MainActor
    func testLoadedAddressesSortFavoritesFirstThenCaseInsensitively() async throws {
        let model = try await makeRestoredModel(routes: ["/list": (testListBody, 200)]).model

        await model.refresh()

        XCTAssertEqual(
            addresses(in: model.phase)?.map(\.address),
            ["Zeta@z9.cabalmail.com", "alpha@a1.cabalmail.com", "Beta@b2.cabalmail.net"],
            "favorites sort ahead of the rest; the remainder is case-insensitive by address"
        )
    }

    @MainActor
    func testExpiredSessionClearsBackToWaiting() async throws {
        // 401 is what `send` maps to `CabalmailError.authExpired`; the model
        // treats a dead refresh token as "re-pair with the phone" rather than
        // leaving a stale failure on screen.
        let fixture = try await makeRestoredModel(routes: ["/list": (Data("{}".utf8), 401)])

        await fixture.model.refresh()

        guard case .waiting = fixture.model.phase else {
            return XCTFail("expected .waiting after an expired session, got \(fixture.model.phase)")
        }
        XCTAssertNil(fixture.model.configuration)
        XCTAssertNil(fixture.defaults.data(forKey: configurationDefaultsKey))
        XCTAssertNil(try fixture.store.get(SecureStoreKey.authTokens))
    }

    @MainActor
    func testServerErrorLeavesRetryableFailureAndKeepsTheSession() async throws {
        let fixture = try await makeRestoredModel(routes: ["/list": (Data("{}".utf8), 500)])

        await fixture.model.refresh()

        guard case .failed = fixture.model.phase else {
            return XCTFail("expected .failed on a 500, got \(fixture.model.phase)")
        }
        // A server-side blip must not throw away a working session.
        XCTAssertNotNil(fixture.defaults.data(forKey: configurationDefaultsKey))
    }

    // MARK: - Revoke

    @MainActor
    func testRevokePrunesTheRowOnlyAfterTheCallSucceeds() async throws {
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/revoke": (Data("{}".utf8), 200),
        ]).model
        await model.refresh()
        let target = addresses(in: model.phase)!.first { $0.address == "alpha@a1.cabalmail.com" }!

        await model.revoke(target)

        XCTAssertEqual(
            addresses(in: model.phase)?.map(\.address),
            ["Zeta@z9.cabalmail.com", "Beta@b2.cabalmail.net"]
        )
    }

    @MainActor
    func testFailedRevokeLeavesTheAddressVisible() async throws {
        // A revoke that didn't happen must not make the address look gone
        // while it still delivers — the model re-syncs from the server.
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/revoke": (Data("{}".utf8), 500),
        ]).model
        await model.refresh()
        let target = addresses(in: model.phase)!.first { $0.address == "alpha@a1.cabalmail.com" }!

        await model.revoke(target)

        XCTAssertEqual(addresses(in: model.phase)?.count, 3)
        XCTAssertTrue(
            addresses(in: model.phase)?.contains { $0.address == "alpha@a1.cabalmail.com" } == true
        )
    }

    // MARK: - Suspend

    @MainActor
    func testSuspendMarksOnlyTheTargetRow() async throws {
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/suspend_address": (Data("{}".utf8), 200),
        ]).model
        await model.refresh()
        let target = addresses(in: model.phase)!.first { $0.address == "alpha@a1.cabalmail.com" }!

        await model.setSuspended(target, to: true)

        XCTAssertEqual(
            addresses(in: model.phase)?.filter(\.suspended).map(\.address),
            ["alpha@a1.cabalmail.com"]
        )
    }

    @MainActor
    func testFailedSuspendLeavesTheRowUnpaused() async throws {
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/suspend_address": (Data("{}".utf8), 500),
        ]).model
        await model.refresh()
        let target = addresses(in: model.phase)!.first { $0.address == "alpha@a1.cabalmail.com" }!

        await model.setSuspended(target, to: true)

        XCTAssertEqual(addresses(in: model.phase)?.filter(\.suspended).count, 0)
    }

    // MARK: - Domain picker

    @MainActor
    func testDomainsIntersectWithTheCallersAllowList() async throws {
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/list_my_domains": (Data(#"{"Domains":["cabalmail.net"]}"#.utf8), 200),
        ]).model
        // Before the fetch the model trusts the deployment's configured list.
        XCTAssertEqual(model.domains.map(\.domain), ["cabalmail.com", "cabalmail.net"])

        await model.loadAllowedDomains()

        XCTAssertEqual(
            model.domains.map(\.domain),
            ["cabalmail.net"],
            "the wrist must not offer an apex /new would reject"
        )
    }

    @MainActor
    func testDomainLookupFailureFallsBackToTheConfiguredList() async throws {
        let model = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/list_my_domains": (Data("{}".utf8), 500),
        ]).model

        await model.loadAllowedDomains()

        // Silent-fail keeps the picker usable; `/new` is the real gate.
        XCTAssertEqual(model.domains.map(\.domain), ["cabalmail.com", "cabalmail.net"])
    }

    // MARK: - Create

    @MainActor
    func testCreateAddressComposesTheAddressFromItsParts() async throws {
        let fixture = try await makeRestoredModel(routes: [
            "/list": (testListBody, 200),
            "/new": (Data("{}".utf8), 200),
        ])

        try await fixture.model.createAddress(
            username: "h7k2m9pq",
            subdomain: "x4n8w2jb",
            domain: "cabalmail.com",
            comment: "Hardware store"
        )

        let body = await fixture.transport.bodies(forPathSuffix: "/new").first
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any]
        XCTAssertEqual(sent?["address"] as? String, "h7k2m9pq@x4n8w2jb.cabalmail.com")
    }

    @MainActor
    func testCreateAddressWithoutASessionThrowsRatherThanSilentlyDropping() async {
        // No stored configuration and no tokens: `start()` leaves the model
        // in `.waiting` with no client behind it.
        let model = WatchAppModel(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        model.start()

        do {
            try await model.createAddress(
                username: "a", subdomain: "b", domain: "cabalmail.com", comment: nil
            )
            XCTFail("expected a throw with no session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("expected CabalmailError.notSignedIn, got \(error)")
        }
    }

    // MARK: - Session lifecycle

    @MainActor
    func testStartWithoutStoredTokensStaysWaiting() throws {
        // The configuration alone is not a session: without tokens in the
        // secure store the watch has to be re-paired.
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode(testConfiguration), forKey: configurationDefaultsKey)
        let model = WatchAppModel(secureStore: InMemorySecureStore(), defaults: defaults)

        model.start()

        guard case .waiting = model.phase else {
            return XCTFail("expected .waiting with no stored tokens, got \(model.phase)")
        }
        XCTAssertNil(model.configuration)
    }

    @MainActor
    func testClearWipesEverythingTheHandoffLeftBehind() async throws {
        let fixture = try await makeRestoredModel(routes: ["/list": (testListBody, 200)])
        await fixture.model.refresh()
        XCTAssertNotNil(fixture.model.configuration)

        fixture.model.clear()

        guard case .waiting = fixture.model.phase else {
            return XCTFail("expected .waiting after clear, got \(fixture.model.phase)")
        }
        XCTAssertNil(fixture.model.configuration)
        XCTAssertNil(fixture.defaults.data(forKey: configurationDefaultsKey))
        XCTAssertNil(try fixture.store.get(SecureStoreKey.authTokens))
        XCTAssertNil(try fixture.store.get(SecureStoreKey.imapUsername))
    }

    @MainActor
    func testApplyPersistsTheHandoffConfigurationAndAdoptsItsTokens() async {
        let transport = RoutingTransport(["/list": (testListBody, 200)])
        let defaults = makeDefaults()
        let adopted = AdoptRecorder()
        let model = WatchAppModel(secureStore: InMemorySecureStore(), defaults: defaults) { config, _ in
            WatchSession(
                apiClient: URLSessionApiClient(
                    configuration: config,
                    authService: StubAuthService(),
                    transport: transport
                ),
                adopt: { _, username in await adopted.record(username) }
            )
        }

        model.apply(
            WatchHandoff(
                configuration: testConfiguration,
                tokens: AuthTokens(
                    idToken: "id",
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: Date().addingTimeInterval(3600)
                ),
                username: "alice"
            )
        )

        XCTAssertEqual(model.configuration?.controlDomain, testConfiguration.controlDomain)
        XCTAssertNotNil(
            defaults.data(forKey: configurationDefaultsKey),
            "a restart must find the handed-off configuration"
        )
        // `apply` adopts on a detached task; give it a turn before asserting.
        for _ in 0..<500 where await adopted.usernames.isEmpty {
            await Task.yield()
        }
        let seen = await adopted.usernames
        XCTAssertEqual(seen, ["alice"])
    }
}
