import Foundation

/// Interface surfaced to the app target and to `ApiClient`/`ImapClient`/`SmtpClient`.
///
/// The React app uses `amazon-cognito-identity-js`. The Apple equivalent
/// described in `docs/0.6.0/ios-client-plan.md` is **AWS Amplify Swift**, but
/// the current scaffold deliberately avoids a ~2 MB external dependency —
/// the Cognito user pool is configured with `explicit_auth_flows =
/// ["USER_PASSWORD_AUTH"]` (see `terraform/infra/modules/user_pool/main.tf`),
/// so the cleartext-flow JSON API is sufficient. The Amplify path can be
/// swapped in behind this protocol later without touching call-sites.
public protocol AuthService: Sendable {
    func signIn(username: String, password: String) async throws
    func signUp(username: String, password: String, email: String?, phone: String?) async throws
    func confirmSignUp(username: String, code: String) async throws
    func resendConfirmationCode(username: String) async throws
    func forgotPassword(username: String) async throws
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws
    func signOut() async throws

    /// Fresh ID token for attaching to API requests; refreshes automatically.
    func currentIdToken() async throws -> String

    /// Cognito username + password persisted at sign-in. Used by the IMAP and
    /// SMTP clients to authenticate against Dovecot and Sendmail-submission,
    /// both of which authenticate against the same Cognito user pool.
    func currentImapCredentials() async throws -> ImapCredentials

    /// Tokens currently in the secure store, or nil if signed out. Exposed
    /// for observers (e.g. a SwiftUI `@Observable` that mirrors the auth state).
    func currentTokens() async -> AuthTokens?
}

/// Concrete Cognito IdP implementation of `AuthService`.
///
/// All operations POST to `https://cognito-idp.{region}.amazonaws.com/` with
/// JSON bodies and an `X-Amz-Target` header. This is the raw AWS REST API
/// that every Cognito SDK wraps.
public actor CognitoAuthService: AuthService {
    private let configuration: Configuration
    private let transport: HTTPTransport
    private let secureStore: SecureStore
    private let clock: @Sendable () -> Date

    public init(
        configuration: Configuration,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        secureStore: SecureStore,
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.secureStore = secureStore
        self.clock = clock
    }

    // MARK: - Sign-in flow

    public func signIn(username: String, password: String) async throws {
        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": configuration.cognito.clientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        let response = try await call("InitiateAuth", body: body)
        let tokens = try parseAuthResult(response)
        try persist(tokens: tokens)
        try secureStore.setString(username, forKey: SecureStoreKey.imapUsername)
        try secureStore.setString(password, forKey: SecureStoreKey.imapPassword)
    }

    public func signUp(
        username: String,
        password: String,
        email: String?,
        phone: String?
    ) async throws {
        var attributes: [[String: String]] = []
        if let email, !email.isEmpty {
            attributes.append(["Name": "email", "Value": email])
        }
        if let phone, !phone.isEmpty {
            attributes.append(["Name": "phone_number", "Value": phone])
        }
        let body: [String: Any] = [
            "ClientId": configuration.cognito.clientId,
            "Username": username,
            "Password": password,
            "UserAttributes": attributes,
        ]
        _ = try await call("SignUp", body: body)
    }

    public func confirmSignUp(username: String, code: String) async throws {
        let body: [String: Any] = [
            "ClientId": configuration.cognito.clientId,
            "Username": username,
            "ConfirmationCode": code,
        ]
        _ = try await call("ConfirmSignUp", body: body)
    }

    public func resendConfirmationCode(username: String) async throws {
        let body: [String: Any] = [
            "ClientId": configuration.cognito.clientId,
            "Username": username,
        ]
        _ = try await call("ResendConfirmationCode", body: body)
    }

    public func forgotPassword(username: String) async throws {
        let body: [String: Any] = [
            "ClientId": configuration.cognito.clientId,
            "Username": username,
        ]
        _ = try await call("ForgotPassword", body: body)
    }

    public func confirmForgotPassword(
        username: String,
        code: String,
        newPassword: String
    ) async throws {
        let body: [String: Any] = [
            "ClientId": configuration.cognito.clientId,
            "Username": username,
            "ConfirmationCode": code,
            "Password": newPassword,
        ]
        _ = try await call("ConfirmForgotPassword", body: body)
    }

    public func signOut() async throws {
        try secureStore.remove(SecureStoreKey.authTokens)
        try secureStore.remove(SecureStoreKey.imapUsername)
        try secureStore.remove(SecureStoreKey.imapPassword)
    }

    // MARK: - Token access

    public func currentIdToken() async throws -> String {
        guard let tokens = try loadTokens() else {
            throw CabalmailError.notSignedIn
        }
        if !tokens.isExpired(now: clock()) {
            return tokens.idToken
        }
        let refreshed = try await refresh(using: tokens)
        try persist(tokens: refreshed)
        return refreshed.idToken
    }

    public func currentImapCredentials() async throws -> ImapCredentials {
        guard
            let username = try secureStore.getString(SecureStoreKey.imapUsername),
            let password = try secureStore.getString(SecureStoreKey.imapPassword)
        else {
            throw CabalmailError.notSignedIn
        }
        return ImapCredentials(username: username, password: password)
    }

    public func currentTokens() async -> AuthTokens? {
        (try? loadTokens()) ?? nil
    }

    // MARK: - Internal

    private func refresh(using tokens: AuthTokens) async throws -> AuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw CabalmailError.authExpired
        }
        let body: [String: Any] = [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": configuration.cognito.clientId,
            "AuthParameters": [
                "REFRESH_TOKEN": refreshToken,
            ],
        ]
        let response = try await call("InitiateAuth", body: body)
        // REFRESH_TOKEN_AUTH omits the refresh token from the response — reuse
        // the existing one so subsequent refreshes keep working.
        var refreshed = try parseAuthResult(response)
        if refreshed.refreshToken == nil {
            refreshed = AuthTokens(
                idToken: refreshed.idToken,
                accessToken: refreshed.accessToken,
                refreshToken: refreshToken,
                tokenType: refreshed.tokenType,
                expiresAt: refreshed.expiresAt
            )
        }
        return refreshed
    }

    private func persist(tokens: AuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try secureStore.set(data, forKey: SecureStoreKey.authTokens)
    }

    private func loadTokens() throws -> AuthTokens? {
        guard let data = try secureStore.get(SecureStoreKey.authTokens) else { return nil }
        return try JSONDecoder().decode(AuthTokens.self, from: data)
    }

    // MARK: - Cognito IdP wire

    private func cognitoURL() throws -> URL {
        guard let url = URL(string: "https://cognito-idp.\(configuration.cognito.region).amazonaws.com/") else {
            throw CabalmailError.notConfigured
        }
        return url
    }

    private func call(_ target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try cognitoURL())
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            let (code, message) = parseError(data)
            if code == "NotAuthorizedException" {
                throw CabalmailError.invalidCredentials
            }
            throw CabalmailError.server(code: code, message: message)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func parseError(_ data: Data) -> (code: String, message: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Unknown", String(data: data, encoding: .utf8) ?? "")
        }
        // Cognito errors come back either as `{__type: "...", message: "..."}`
        // or `{code: "...", message: "..."}` depending on the operation.
        let code = (obj["__type"] as? String)
            .flatMap { $0.split(separator: "#").last.map(String.init) }
            ?? (obj["code"] as? String)
            ?? "Unknown"
        let message = obj["message"] as? String ?? obj["Message"] as? String ?? ""
        return (code, message)
    }

    private func parseAuthResult(_ response: [String: Any]) throws -> AuthTokens {
        guard let result = response["AuthenticationResult"] as? [String: Any] else {
            // A `ChallengeName` response is technically valid (MFA, new-password-
            // required, etc.) but the pool isn't configured for any challenges,
            // so surface it as a protocol error for now.
            if let challenge = response["ChallengeName"] as? String {
                throw CabalmailError.protocolError("Unhandled challenge: \(challenge)")
            }
            throw CabalmailError.decoding("Missing AuthenticationResult")
        }
        guard
            let idToken = result["IdToken"] as? String,
            let accessToken = result["AccessToken"] as? String
        else {
            throw CabalmailError.decoding("Missing tokens in AuthenticationResult")
        }
        let refreshToken = result["RefreshToken"] as? String
        let expiresIn = (result["ExpiresIn"] as? Int) ?? 3600
        let tokenType = (result["TokenType"] as? String) ?? "Bearer"
        return AuthTokens(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: clock().addingTimeInterval(TimeInterval(expiresIn))
        )
    }
}
