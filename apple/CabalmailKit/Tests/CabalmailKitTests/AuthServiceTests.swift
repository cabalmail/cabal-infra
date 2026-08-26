import XCTest
@testable import CabalmailKit

// Shared by both test classes below (split to satisfy SwiftLint's
// type_body_length cap).
private func makeConfiguration() -> Configuration {
    Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
    )
}

final class AuthServiceTests: XCTestCase {
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

        let result = try await service.signIn(username: "alice", password: "hunter2")
        XCTAssertEqual(result, .signedIn)

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

        _ = try await service.signIn(username: "alice", password: "hunter2")
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
            _ = try await service.signIn(username: "alice", password: "wrong")
            XCTFail("Expected invalid credentials error")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    func testLambdaTriggerRejectionStripsWrapperAndDoubledPeriod() async throws {
        let errorType = "com.amazonaws.cognito.identity.model#UserLambdaValidationException"
        let wrapped = "PreTokenGeneration failed with error This account requires "
            + "multi-factor authentication. Enroll an authenticator app under Security.."
        let body = "{\"__type\":\"\(errorType)\",\"message\":\"\(wrapped)\"}"
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 400)])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        do {
            _ = try await service.signIn(username: "alice", password: "hunter2")
            XCTFail("Expected a server error")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .server(
                code: "UserLambdaValidationException",
                message: "This account requires multi-factor authentication. "
                    + "Enroll an authenticator app under Security."
            ))
        }
    }

    func testStripLambdaTriggerWrapperLeavesOrdinaryMessagesAlone() {
        // No wrapper at all.
        XCTAssertEqual(
            CognitoAuthService.stripLambdaTriggerWrapper(from: "Invitation code required"),
            "Invitation code required"
        )
        // A mid-sentence occurrence (the lead-in contains spaces) is a
        // real message, not Cognito's wrapper.
        XCTAssertEqual(
            CognitoAuthService.stripLambdaTriggerWrapper(from: "The last attempt failed with error 42"),
            "The last attempt failed with error 42"
        )
        // A trigger message with a single terminal period keeps it.
        let singlePeriod = "PreSignUp_SignUp failed with error Signups are closed."
        XCTAssertEqual(
            CognitoAuthService.stripLambdaTriggerWrapper(from: singlePeriod),
            "Signups are closed."
        )
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
        _ = try await service.signIn(username: "alice", password: "hunter2")
        try await service.signOut()
        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected notSignedIn")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    // #1288: Cognito answers `NotAuthorizedException` to a refresh whose
    // token has expired or been revoked, exactly as it does to a sign-in
    // with a bad password. Only the refresh path knows nobody typed
    // anything, so it is the one that has to say "session expired".
    func testExpiredRefreshTokenMapsToAuthExpired() async throws {
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
        let errorType = "com.amazonaws.cognito.identity.model#NotAuthorizedException"
        let refusal = """
        {"__type":"\(errorType)","message":"Refresh Token has been revoked"}
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(initialTokens.utf8), 200),
            (Data(refusal.utf8), 400),
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

        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected the refused refresh to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }
        // The refusal has to have come from the refresh, not the sign-in.
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        let refreshBody = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(refreshBody?["AuthFlow"] as? String, "REFRESH_TOKEN_AUTH")
    }

}

/// MFA challenge and TOTP enrollment coverage (identity plan Phase 1).
final class AuthServiceMfaTests: XCTestCase {
    func testTotpChallengeThenSubmitCodeSignsIn() async throws {
        let challenge = """
        {"ChallengeName":"SOFTWARE_TOKEN_MFA","Session":"sess-1","ChallengeParameters":{}}
        """
        let authResult = """
        {"AuthenticationResult":{"IdToken":"I","AccessToken":"A","RefreshToken":"R","ExpiresIn":3600}}
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(challenge.utf8), 200),
            (Data(authResult.utf8), 200),
        ])
        let store = InMemorySecureStore()
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: store
        )

        let result = try await service.signIn(username: "alice", password: "hunter2")
        XCTAssertEqual(result, .mfaCodeRequired(.totp))
        // No tokens or credentials may exist until the challenge passes.
        do {
            _ = try await service.currentIdToken()
            XCTFail("Expected notSignedIn before the challenge completes")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        }

        try await service.submitMfaCode("123456")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.RespondToAuthChallenge"
        )
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["ChallengeName"] as? String, "SOFTWARE_TOKEN_MFA")
        XCTAssertEqual(body?["Session"] as? String, "sess-1")
        let responses = body?["ChallengeResponses"] as? [String: String]
        XCTAssertEqual(responses?["USERNAME"], "alice")
        XCTAssertEqual(responses?["SOFTWARE_TOKEN_MFA_CODE"], "123456")

        let token = try await service.currentIdToken()
        XCTAssertEqual(token, "I")
        let creds = try await service.currentImapCredentials()
        XCTAssertEqual(creds.username, "alice")
        XCTAssertEqual(creds.password, "hunter2")
    }

    func testSubmitMfaCodeWithoutChallengeThrows() async throws {
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: RecordingHTTPTransport(responses: []),
            secureStore: InMemorySecureStore()
        )
        do {
            try await service.submitMfaCode("123456")
            XCTFail("Expected notSignedIn")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        }
    }

    func testUnknownChallengeStillThrows() async throws {
        let challenge = """
        {"ChallengeName":"NEW_PASSWORD_REQUIRED","Session":"sess-1"}
        """
        let http = RecordingHTTPTransport(responses: [(Data(challenge.utf8), 200)])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        do {
            _ = try await service.signIn(username: "alice", password: "hunter2")
            XCTFail("Expected protocolError")
        } catch let error as CabalmailError {
            guard case .protocolError(let text) = error else {
                return XCTFail("Expected protocolError, got \(error)")
            }
            XCTAssertTrue(text.contains("NEW_PASSWORD_REQUIRED"))
        }
    }

    func testTotpEnrollmentFlow() async throws {
        let authResult = """
        {"AuthenticationResult":{"IdToken":"I","AccessToken":"ACCESS","RefreshToken":"R","ExpiresIn":3600}}
        """
        let associate = """
        {"SecretCode":"SECRETKEY234567"}
        """
        let verify = """
        {"Status":"SUCCESS"}
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(authResult.utf8), 200),
            (Data(associate.utf8), 200),
            (Data(verify.utf8), 200),
            (Data("{}".utf8), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        let secret = try await service.beginTotpEnrollment()
        XCTAssertEqual(secret, "SECRETKEY234567")

        try await service.confirmTotpEnrollment(code: "654321")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.AssociateSoftwareToken"
        )
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.VerifySoftwareToken"
        )
        let verifyBody = try JSONSerialization.jsonObject(with: requests[2].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(verifyBody?["AccessToken"] as? String, "ACCESS")
        XCTAssertEqual(verifyBody?["UserCode"] as? String, "654321")
        XCTAssertEqual(
            requests[3].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.SetUserMFAPreference"
        )
        let prefBody = try JSONSerialization.jsonObject(with: requests[3].httpBody ?? Data()) as? [String: Any]
        let settings = prefBody?["SoftwareTokenMfaSettings"] as? [String: Bool]
        XCTAssertEqual(settings?["Enabled"], true)
        XCTAssertEqual(settings?["PreferredMfa"], true)
    }

    func testTotpEnabledReadsGetUser() async throws {
        let authResult = """
        {"AuthenticationResult":{"IdToken":"I","AccessToken":"ACCESS","RefreshToken":"R","ExpiresIn":3600}}
        """
        let getUser = """
        {"Username":"alice","UserMFASettingList":["SOFTWARE_TOKEN_MFA"]}
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(authResult.utf8), 200),
            (Data(getUser.utf8), 200),
        ])
        let service = CognitoAuthService(
            configuration: makeConfiguration(),
            transport: http,
            secureStore: InMemorySecureStore()
        )
        _ = try await service.signIn(username: "alice", password: "hunter2")

        let enabled = try await service.totpEnabled()
        XCTAssertTrue(enabled)
        let requests = await http.requests
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "X-Amz-Target"),
            "AWSCognitoIdentityProviderService.GetUser"
        )
    }
}

/// Tiny mutable box used to advance the clock inside a @Sendable closure.
final class ClockReference: @unchecked Sendable {
    var value: Date
    init(value: Date) { self.value = value }
}
