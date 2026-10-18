import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// `AuthService.isAdmin()` is derived from whatever tokens are stored at the
/// moment it is asked, so it has to follow every change to them: sign-in,
/// sign-out, a refresh whose new ID token gained or lost the group, and an
/// account switch (auth parity plan, C1).
final class AuthServiceAdminTests: XCTestCase {
    private let store = InMemorySecureStore()

    private static let adminIdToken = TestFixtures.idToken(claims: [
        "cognito:username": "alice", "cognito:groups": ["admin"],
    ])
    private static let userIdToken = TestFixtures.idToken(claims: ["cognito:username": "alice"])

    private func service(transport: HTTPTransport = NullHTTPTransport()) -> CognitoAuthService {
        CognitoAuthService(configuration: TestFixtures.makeConfiguration(), transport: transport, secureStore: store)
    }

    private static func tokens(_ idToken: String, expiresIn: TimeInterval = 3600) -> AuthTokens {
        AuthTokens(
            idToken: idToken,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func refreshReply(_ idToken: String) -> Data {
        let result: [String: Any] = [
            "IdToken": idToken, "AccessToken": "access-2", "ExpiresIn": 3600, "TokenType": "Bearer",
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: ["AuthenticationResult": result])
    }

    func testSignedOutIsNotAdmin() async {
        let isAdmin = await service().isAdmin()
        XCTAssertFalse(isAdmin)
    }

    func testAdminFollowsSignInAndSignOut() async throws {
        let http = RecordingHTTPTransport(responses: [(Self.refreshReply(Self.adminIdToken), 200)])
        let session = service(transport: http)
        _ = try await session.signIn(username: "alice", password: "hunter2")
        let signedIn = await session.isAdmin()
        XCTAssertTrue(signedIn)

        try await session.signOut()
        let signedOut = await session.isAdmin()
        XCTAssertFalse(signedOut)
    }

    /// Group membership changes reach a client only in the next token
    /// Cognito issues, so the refresh is where a grant or a removal shows up.
    func testARefreshThatGrantsTheGroupMakesTheUserAdmin() async throws {
        let http = RecordingHTTPTransport(responses: [(Self.refreshReply(Self.adminIdToken), 200)])
        let session = service(transport: http)
        try await session.adopt(tokens: Self.tokens(Self.userIdToken, expiresIn: -60))
        let before = await session.isAdmin()
        XCTAssertFalse(before)

        _ = try await session.currentIdToken()
        let after = await session.isAdmin()
        XCTAssertTrue(after)
    }

    func testARefreshThatRemovesTheGroupEndsAdmin() async throws {
        let http = RecordingHTTPTransport(responses: [(Self.refreshReply(Self.userIdToken), 200)])
        let session = service(transport: http)
        try await session.adopt(tokens: Self.tokens(Self.adminIdToken))
        let before = await session.isAdmin()
        XCTAssertTrue(before)

        _ = try await session.refreshIdToken(replacing: Self.adminIdToken)
        let after = await session.isAdmin()
        XCTAssertFalse(after)
    }

    /// Every session on the device keeps its tokens in one keychain item
    /// (#1852). After a switch the ended admin session answers false, and
    /// the next account answers for itself.
    func testAnAccountSwitchAnswersForTheAccountNowSignedIn() async throws {
        let admin = service()
        try await admin.adopt(tokens: Self.tokens(Self.adminIdToken))
        try await admin.signOut()
        let next = service()
        try await next.adopt(tokens: Self.tokens(Self.userIdToken))

        let endedSession = await admin.isAdmin()
        let nextSession = await next.isAdmin()
        XCTAssertFalse(endedSession, "the ended session reads none of the next account's tokens")
        XCTAssertFalse(nextSession, "the next account is not an admin")
    }
}
