import XCTest
@testable import CabalmailKit

/// `OfflineLaunch.validateStoredSession`: restore's token check, which must
/// tell "Cognito is unreachable" apart from "Cognito refused the session".
final class OfflineLaunchTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "us-east-1_ABC", clientId: "clientX")
    )

    /// A service holding an ID token that expired an hour ago, so the check
    /// has to refresh through `transport`.
    private func serviceWithExpiredToken(transport: HTTPTransport) async throws -> CognitoAuthService {
        let service = CognitoAuthService(
            configuration: Self.configuration,
            transport: transport,
            secureStore: InMemorySecureStore()
        )
        let expired = AuthTokens(
            idToken: "OLD-ID",
            accessToken: "OLD-ACCESS",
            refreshToken: "REFRESH",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(-3600)
        )
        try await service.adopt(tokens: expired, username: "alice")
        return service
    }

    func testUnreachableCognitoPasses() async throws {
        let offline = ScriptedHTTPTransport { _ in
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
        let service = try await serviceWithExpiredToken(transport: offline)
        try await OfflineLaunch.validateStoredSession(service)
    }

    func testRefusedRefreshStillThrowsAuthExpired() async throws {
        let errorType = "com.amazonaws.cognito.identity.model#NotAuthorizedException"
        let refusal = Data("""
        {"__type":"\(errorType)","message":"Refresh Token has been revoked"}
        """.utf8)
        let http = RecordingHTTPTransport(responses: [(refusal, 400)])
        let service = try await serviceWithExpiredToken(transport: http)
        do {
            try await OfflineLaunch.validateStoredSession(service)
            XCTFail("expected the refused refresh to throw")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }
    }

    func testMissingTokensStillThrowNotSignedIn() async {
        let service = CognitoAuthService(
            configuration: Self.configuration,
            transport: ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") },
            secureStore: InMemorySecureStore()
        )
        do {
            try await OfflineLaunch.validateStoredSession(service)
            XCTFail("expected notSignedIn")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
