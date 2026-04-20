import XCTest
@testable import CabalmailKit

final class AuthServiceTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
        )
    }

    func testSignInStoresTokensAndCredentials() async throws {
        let authResult = """
        {
          "AuthenticationResult": {
            "IdToken": "ID-TOKEN",
            "AccessToken": "ACCESS-TOKEN",
            "RefreshToken": "REFRESH-TOKEN",
            "ExpiresIn": 3600,
            "TokenType": "Bearer"
          }
        }
        """
        let http = RecordingHTTPTransport(responses: [(Data(authResult.utf8), 200)])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )

        try await service.signIn(username: "alice", password: "hunter2")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.url?.host, "cognito-idp.us-east-1.amazonaws.com")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.InitiateAuth"
        )
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["AuthFlow"] as? String, "USER_PASSWORD_AUTH")
        XCTAssertEqual(body?["ClientId"] as? String, "clientX")

        let token = try await service.currentIdToken()
        XCTAssertEqual(token, "ID-TOKEN")
        let creds = try await service.currentImapCredentials()
        XCTAssertEqual(creds.username, "alice")
        XCTAssertEqual(creds.password, "hunter2")
    }

    func testCurrentIdTokenRefreshesWhenExpired() async throws {
        let initialTokens = """
        {
          "AuthenticationResult": {
            "IdToken": "OLD-ID",
            "AccessToken": "OLD-ACCESS",
            "RefreshToken": "REFRESH",
            "ExpiresIn": 1,
            "TokenType": "Bearer"
          }
        }
        """
        let refreshedTokens = """
        {
          "AuthenticationResult": {
            "IdToken": "NEW-ID",
            "AccessToken": "NEW-ACCESS",
            "ExpiresIn": 3600,
            "TokenType": "Bearer"
          }
        }
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(initialTokens.utf8), 200),
            (Data(refreshedTokens.utf8), 200),
        ])
        let clockRef = ClockReference(value: Date(timeIntervalSince1970: 1_000))
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore(),
            clock: { clockRef.value }
        )

        try await service.signIn(username: "alice", password: "hunter2")
        clockRef.value = Date(timeIntervalSince1970: 1_100)

        let token = try await service.currentIdToken()
        XCTAssertEqual(token, "NEW-ID")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)

        let refreshBody = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(refreshBody?["AuthFlow"] as? String, "REFRESH_TOKEN_AUTH")
    }

    func testInvalidCredentialsMaps() async throws {
        let errorType = "com.amazonaws.cognito.identity.model#NotAuthorizedException"
        let body = """
        {"__type":"\(errorType)","message":"Incorrect username or password."}
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 400)])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        do {
            try await service.signIn(username: "alice", password: "wrong")
            XCTFail("Expected invalid credentials error")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    func testSignOutClearsStore() async throws {
        let authResult = """
        {"AuthenticationResult":{"IdToken":"I","AccessToken":"A","RefreshToken":"R","ExpiresIn":3600}}
        """
        let http = RecordingHTTPTransport(responses: [(Data(authResult.utf8), 200)])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )
        try await service.signIn(username: "alice", password: "hunter2")
        try await service.signOut()
        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected notSignedIn")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }
}

/// Tiny mutable box used to advance the clock inside a @Sendable closure.
final class ClockReference: @unchecked Sendable {
    var value: Date
    init(value: Date) { self.value = value }
}
