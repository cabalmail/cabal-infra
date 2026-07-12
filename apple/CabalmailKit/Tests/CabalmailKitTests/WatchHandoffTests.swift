import XCTest
@testable import CabalmailKit

final class WatchHandoffTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
        )
    }

    private func makeTokens(expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000)) -> AuthTokens {
        AuthTokens(
            idToken: "ID-TOKEN",
            accessToken: "ACCESS-TOKEN",
            refreshToken: "REFRESH-TOKEN",
            tokenType: "Bearer",
            expiresAt: expiresAt
        )
    }

    // MARK: - Application-context codec

    func testApplicationContextRoundTrip() throws {
        let handoff = WatchHandoff(
            configuration: makeConfiguration(),
            tokens: makeTokens(),
            username: "alice"
        )

        let context = try handoff.applicationContext()
        let decoded = WatchHandoff.from(applicationContext: context)

        XCTAssertEqual(decoded, handoff)
        XCTAssertFalse(WatchHandoff.isSignedOut(applicationContext: context))
    }

    func testVersionMismatchDecodesToNil() throws {
        let handoff = WatchHandoff(
            configuration: makeConfiguration(),
            tokens: makeTokens(),
            username: "alice"
        )

        var context = try handoff.applicationContext()
        context[WatchHandoff.contextVersionKey] = WatchHandoff.contextVersion + 1

        XCTAssertNil(WatchHandoff.from(applicationContext: context))
        // A future version isn't this version's sign-out signal either.
        XCTAssertFalse(WatchHandoff.isSignedOut(applicationContext: context))
    }

    func testGarbagePayloadDecodesToNil() {
        let context: [String: Any] = [
            WatchHandoff.contextVersionKey: WatchHandoff.contextVersion,
            WatchHandoff.contextPayloadKey: Data("not json".utf8),
        ]

        XCTAssertNil(WatchHandoff.from(applicationContext: context))
    }

    func testSignedOutContext() {
        let context = WatchHandoff.signedOutContext()

        XCTAssertNil(WatchHandoff.from(applicationContext: context))
        XCTAssertTrue(WatchHandoff.isSignedOut(applicationContext: context))
        // An empty / foreign dictionary is not a sign-out signal.
        XCTAssertFalse(WatchHandoff.isSignedOut(applicationContext: [:]))
    }

    // MARK: - Token adoption (the watch's receive path)

    func testAdoptedTokensServeCurrentIdToken() async throws {
        let http = RecordingHTTPTransport(responses: [])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )

        try await service.adopt(tokens: makeTokens(), username: "alice")

        // A fresh adopted token is returned as-is — no network traffic.
        let token = try await service.currentIdToken()
        XCTAssertEqual(token, "ID-TOKEN")
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAdoptedExpiredTokensRefreshWithAdoptedRefreshToken() async throws {
        let refreshed = """
        {
          "AuthenticationResult": {
            "IdToken": "NEW-ID",
            "AccessToken": "NEW-ACCESS",
            "ExpiresIn": 3600,
            "TokenType": "Bearer"
          }
        }
        """
        let http = RecordingHTTPTransport(responses: [(Data(refreshed.utf8), 200)])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )

        // Adopt tokens that are already expired — the realistic hand-off
        // case when the watch has been out of range for an hour.
        try await service.adopt(
            tokens: makeTokens(expiresAt: Date(timeIntervalSinceNow: -60)),
            username: "alice"
        )

        let token = try await service.currentIdToken()

        XCTAssertEqual(token, "NEW-ID")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["AuthFlow"] as? String, "REFRESH_TOKEN_AUTH")
        let params = body?["AuthParameters"] as? [String: Any]
        XCTAssertEqual(params?["REFRESH_TOKEN"] as? String, "REFRESH-TOKEN")
    }

    func testAdoptDoesNotInventImapCredentials() async throws {
        let http = RecordingHTTPTransport(responses: [])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )

        try await service.adopt(tokens: makeTokens(), username: "alice")

        // The password never rides the hand-off, so the IMAP/SMTP credential
        // pair must stay unavailable rather than surfacing a bogus one.
        do {
            _ = try await service.currentImapCredentials()
            XCTFail("expected notSignedIn")
        } catch let error as CabalmailError {
            guard case .notSignedIn = error else {
                XCTFail("expected notSignedIn, got \(error)")
                return
            }
        }
    }
}
