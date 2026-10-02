import Foundation
@testable import CabalmailKit

// MARK: - HTTP fake

struct ScriptedHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

/// Records every request and replies from a FIFO queue of canned responses.
actor RecordingHTTPTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CabalmailError.transport("RecordingHTTPTransport ran out of responses")
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

// MARK: - Auth fake

/// AuthService double with scripted behavior. Every method is no-op by
/// default; tests can seed a fixed ID token.
actor StubAuthService: AuthService {
    var tokens: AuthTokens?
    var idTokenCallCount = 0
    var forcedRefreshCount = 0

    init(
        tokens: AuthTokens? = AuthTokens(
            idToken: "idtoken",
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
    ) {
        self.tokens = tokens
    }

    func signIn(username: String, password: String) async throws -> SignInResult {
        .signedIn
    }

    func submitMfaCode(_ code: String) async throws {}
    func totpEnabled() async throws -> Bool { false }
    func beginTotpEnrollment() async throws -> String { "STUBSECRET" }
    func confirmTotpEnrollment(code: String) async throws {}
    func disableTotp() async throws {}

    func signUp(username: String, password: String, email: String?, phone: String?) async throws {}
    func confirmSignUp(username: String, code: String) async throws {}
    func resendConfirmationCode(username: String) async throws {}
    func forgotPassword(username: String) async throws {}
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws {}

    func signOut() async throws {
        tokens = nil
    }

    func currentIdToken() async throws -> String {
        idTokenCallCount += 1
        guard let tokens else { throw CabalmailError.notSignedIn }
        return tokens.idToken
    }

    func refreshIdToken(replacing rejected: String?) async throws -> String {
        forcedRefreshCount += 1
        return try await currentIdToken()
    }

    func currentTokens() async -> AuthTokens? {
        tokens
    }
}
