import XCTest
@testable import CabalmailKit

/// A 401 from the API must force a Cognito refresh even when the stored
/// token still looks fresh by the device clock, and a burst of callers that
/// all need a refresh must share one `InitiateAuth` round-trip.
final class AuthServiceRefreshTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
        )
    }

    private func tokensJSON(id: String, expiresIn: Int, refresh: String? = "REFRESH") -> Data {
        var result: [String: Any] = [
            "IdToken": id,
            "AccessToken": "ACCESS-\(id)",
            "ExpiresIn": expiresIn,
            "TokenType": "Bearer",
        ]
        if let refresh { result["RefreshToken"] = refresh }
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: ["AuthenticationResult": result])
    }

    private func targets(_ requests: [URLRequest]) -> [String] {
        requests.compactMap { $0.value(forHTTPHeaderField: "X-Amz-Target") }
    }

    func testRefreshIdTokenRefreshesAnUnexpiredRejectedToken() async throws {
        let http = RecordingHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 3600), 200),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        // By the local clock OLD-ID is good for an hour; the cached path
        // hands it back unchanged.
        let cached = try await service.currentIdToken()
        XCTAssertEqual(cached, "OLD-ID")

        let token = try await service.refreshIdToken(replacing: "OLD-ID")
        XCTAssertEqual(token, "NEW-ID")
        let afterRefresh = try await service.currentIdToken()
        XCTAssertEqual(afterRefresh, "NEW-ID")
        // The refresh token survives a refresh response that omits it.
        let stored = await service.currentTokens()
        XCTAssertEqual(stored?.refreshToken, "REFRESH")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["AuthFlow"] as? String, "REFRESH_TOKEN_AUTH")
    }

    func testRefreshIdTokenSkipsRoundTripWhenAlreadyReplaced() async throws {
        let http = RecordingHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 3600), 200),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        let first = try await service.refreshIdToken(replacing: "OLD-ID")
        // A caller whose 401 lands after the first refresh finished still
        // holds OLD-ID; it gets the stored NEW-ID without another refresh.
        let second = try await service.refreshIdToken(replacing: "OLD-ID")
        XCTAssertEqual(first, "NEW-ID")
        XCTAssertEqual(second, "NEW-ID")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testConcurrentForcedRefreshesShareOneRoundTrip() async throws {
        let http = DelayedHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 3600), 200),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.refreshIdToken(replacing: "OLD-ID") }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        XCTAssertEqual(tokens, Array(repeating: "NEW-ID", count: 8))
        let requests = await http.requests
        // Sign-in plus exactly one refresh; a second would have run the
        // transport out of responses and failed the group.
        XCTAssertEqual(targets(requests).count, 2)
    }

    func testConcurrentExpiredCallersShareOneRoundTrip() async throws {
        let http = DelayedHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 1), 200),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
        ])
        let clockRef = ClockReference(value: Date(timeIntervalSince1970: 1_000))
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore(),
            clock: { clockRef.value }
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")
        clockRef.value = Date(timeIntervalSince1970: 1_100)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.currentIdToken() }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        XCTAssertEqual(tokens, Array(repeating: "NEW-ID", count: 8))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    /// End to end through the API client: the 401 retry must not replay the
    /// token the server just rejected (it did, while that token was unexpired
    /// by the local clock).
    func testApiClientReplaysWithRefreshedTokenAfter401() async throws {
        let http = RecordingHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 3600), 200),
            (Data("unauthorized".utf8), 401),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
            (Data("[]".utf8), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: service,
            transport: http
        )

        let addresses = try await client.listAddresses()
        XCTAssertTrue(addresses.isEmpty)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "OLD-ID")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.InitiateAuth"
        )
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "NEW-ID")
    }

    func testSignOutDuringRefreshDoesNotRestoreTokens() async throws {
        let http = DelayedHTTPTransport(responses: [
            (tokensJSON(id: "OLD-ID", expiresIn: 3600), 200),
            (tokensJSON(id: "NEW-ID", expiresIn: 3600, refresh: nil), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        let refresh = Task { try await service.refreshIdToken(replacing: "OLD-ID") }
        // Let the refresh reach the transport, then sign out under it.
        try await waitUntil { await http.requests.count == 2 }
        try await service.signOut()
        _ = try? await refresh.value

        let stored = await service.currentTokens()
        XCTAssertNil(stored)
    }
}

/// `RecordingHTTPTransport` with a pause on every response, so concurrent
/// callers genuinely overlap the Cognito round-trip.
private actor DelayedHTTPTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CabalmailError.transport("DelayedHTTPTransport ran out of responses")
        }
        let (data, status) = responses.removeFirst()
        try await Task.sleep(nanoseconds: 50_000_000)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}
