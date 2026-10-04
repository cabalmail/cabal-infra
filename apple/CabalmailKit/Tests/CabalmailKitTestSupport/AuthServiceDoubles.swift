import Foundation
import CabalmailKit

// The two `AuthService` doubles are deliberately different, not duplicates:
// suites assert on what each hands back, so neither should absorb the other.

/// `AuthService` double with scripted tokens. Every method is a no-op by
/// default; `signOut` drops the tokens, after which `currentIdToken` throws
/// `.notSignedIn`. The ID token `"idtoken"` is what the Kit's API suites
/// expect on the Authorization header, and the two counters let them assert
/// how often a token was read or force-refreshed.
public actor StubAuthService: AuthService {
    public var tokens: AuthTokens?
    public var idTokenCallCount = 0
    public var forcedRefreshCount = 0

    public init(
        tokens: AuthTokens? = AuthTokens(
            idToken: "idtoken",
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
    ) {
        self.tokens = tokens
    }

    public func signIn(username: String, password: String) async throws -> SignInResult {
        .signedIn
    }

    public func submitMfaCode(_ code: String) async throws {}
    public func totpEnabled() async throws -> Bool { false }
    public func beginTotpEnrollment() async throws -> String { "STUBSECRET" }
    public func confirmTotpEnrollment(code: String) async throws {}
    public func disableTotp() async throws {}

    public func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    public func confirmSignUp(username: String, code: String) async throws {}
    public func resendConfirmationCode(username: String) async throws {}
    public func forgotPassword(username: String) async throws {}
    public func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}

    public func signOut() async throws {
        tokens = nil
    }

    public func currentIdToken() async throws -> String {
        idTokenCallCount += 1
        guard let tokens else { throw CabalmailError.notSignedIn }
        return tokens.idToken
    }

    public func refreshIdToken(replacing rejected: String?) async throws -> String {
        forcedRefreshCount += 1
        return try await currentIdToken()
    }

    public func currentTokens() async -> AuthTokens? {
        tokens
    }
}

/// Minimal `AuthService` conformance for clients whose paths never
/// authenticate: it always hands back `"test-token"`, even after `signOut`,
/// and reports no stored tokens.
public actor NullAuthService: AuthService {
    public init() {}

    public func signIn(username: String, password: String) async throws -> SignInResult { .signedIn }
    public func submitMfaCode(_ code: String) async throws {}
    public func totpEnabled() async throws -> Bool { false }
    public func beginTotpEnrollment() async throws -> String { "NULLSECRET" }
    public func confirmTotpEnrollment(code: String) async throws {}
    public func disableTotp() async throws {}
    public func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    public func confirmSignUp(username: String, code: String) async throws {}
    public func resendConfirmationCode(username: String) async throws {}
    public func forgotPassword(username: String) async throws {}
    public func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}
    public func signOut() async throws {}
    public func currentIdToken() async throws -> String { "test-token" }
    public func currentTokens() async -> AuthTokens? { nil }
}
