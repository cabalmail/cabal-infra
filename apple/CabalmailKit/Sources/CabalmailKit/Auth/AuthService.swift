import Foundation

/// Which second factor Cognito is asking for mid-sign-in.
public enum MfaMethod: Sendable, Equatable {
    /// `SOFTWARE_TOKEN_MFA` — a TOTP code from an authenticator app.
    case totp
    /// `SMS_MFA` — a code Cognito just texted to the verified phone.
    case sms

    init?(challengeName: String) {
        switch challengeName {
        case "SOFTWARE_TOKEN_MFA": self = .totp
        case "SMS_MFA": self = .sms
        default: return nil
        }
    }

    var challengeName: String {
        switch self {
        case .totp: return "SOFTWARE_TOKEN_MFA"
        case .sms: return "SMS_MFA"
        }
    }

    /// Key inside `ChallengeResponses` that carries the user's code.
    var responseCodeKey: String {
        switch self {
        case .totp: return "SOFTWARE_TOKEN_MFA_CODE"
        case .sms: return "SMS_MFA_CODE"
        }
    }
}

/// Outcome of `signIn`: either tokens are stored and the session is live,
/// or Cognito answered with an MFA challenge that `submitMfaCode` must
/// complete before any token exists.
public enum SignInResult: Sendable, Equatable {
    case signedIn
    case mfaCodeRequired(MfaMethod)
}

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
    func signIn(username: String, password: String) async throws -> SignInResult
    /// Completes a sign-in that `signIn` answered with `.mfaCodeRequired`.
    /// Throws if no challenge is pending or the code is rejected; a wrong
    /// code leaves the challenge session usable for a retry.
    func submitMfaCode(_ code: String) async throws
    func signUp(username: String, password: String, email: String?, phone: String?) async throws
    func confirmSignUp(username: String, code: String) async throws
    func resendConfirmationCode(username: String) async throws
    func forgotPassword(username: String) async throws
    func confirmForgotPassword(username: String, code: String, newPassword: String) async throws
    func signOut() async throws

    /// TOTP enrollment (identity plan Phase 1). `beginTotpEnrollment`
    /// returns the shared secret to show as an otpauth:// QR / manual key;
    /// `confirmTotpEnrollment` verifies a first code and marks TOTP as the
    /// preferred factor, after which the next sign-in is challenged.
    func totpEnabled() async throws -> Bool
    func beginTotpEnrollment() async throws -> String
    func confirmTotpEnrollment(code: String) async throws
    func disableTotp() async throws

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

    /// Mid-sign-in MFA challenge state. Cognito hands back an opaque
    /// `Session` that `RespondToAuthChallenge` must echo; the username and
    /// password ride along so the IMAP credentials can be persisted only
    /// once the challenge succeeds. Memory-only by design: a relaunch
    /// mid-challenge restarts the sign-in.
    private struct PendingChallenge {
        let method: MfaMethod
        let session: String
        let username: String
        let password: String
    }

    private var pendingChallenge: PendingChallenge?

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

    public func signIn(username: String, password: String) async throws -> SignInResult {
        pendingChallenge = nil
        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": configuration.cognito.clientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        let response = try await call("InitiateAuth", body: body)
        if let challenge = response["ChallengeName"] as? String {
            guard
                let method = MfaMethod(challengeName: challenge),
                let session = response["Session"] as? String
            else {
                // NEW_PASSWORD_REQUIRED, MFA_SETUP, ... — nothing the app
                // flow can produce with the current pool configuration.
                throw CabalmailError.protocolError("Unhandled challenge: \(challenge)")
            }
            pendingChallenge = PendingChallenge(
                method: method,
                session: session,
                username: username,
                password: password
            )
            return .mfaCodeRequired(method)
        }
        let tokens = try parseAuthResult(response)
        try complete(tokens: tokens, username: username, password: password)
        return .signedIn
    }

    fileprivate func complete(tokens: AuthTokens, username: String, password: String) throws {
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
        pendingChallenge = nil
        try secureStore.remove(SecureStoreKey.authTokens)
        try secureStore.remove(SecureStoreKey.imapUsername)
        try secureStore.remove(SecureStoreKey.imapPassword)
    }

    /// Installs externally obtained tokens — the watch app's credential
    /// bootstrap, where the paired iPhone hands its session over via a
    /// `WatchHandoff`. The password never leaves the phone, so
    /// `currentImapCredentials()` stays unavailable on the adopting device;
    /// the API-backed clients only need `currentIdToken()`, which refreshes
    /// off the adopted refresh token.
    public func adopt(tokens: AuthTokens, username: String) throws {
        try persist(tokens: tokens)
        try secureStore.setString(username, forKey: SecureStoreKey.imapUsername)
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
            if code == "UserLambdaValidationException" {
                // A pool trigger (require_admin_mfa, check_invite, ...)
                // rejected the call; the trigger's own message is the
                // user-facing part, not Cognito's wrapper around it.
                throw CabalmailError.server(
                    code: code,
                    message: Self.stripLambdaTriggerWrapper(from: message)
                )
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
            // MFA challenges are handled in signIn before this parser runs;
            // a ChallengeName here (refresh flow, or something new like
            // NEW_PASSWORD_REQUIRED) is genuinely unhandled.
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

// MARK: - Second factor + TOTP enrollment

extension CognitoAuthService {
    public func submitMfaCode(_ code: String) async throws {
        guard let pending = pendingChallenge else {
            throw CabalmailError.notSignedIn
        }
        let body: [String: Any] = [
            "ChallengeName": pending.method.challengeName,
            "ClientId": configuration.cognito.clientId,
            "Session": pending.session,
            "ChallengeResponses": [
                "USERNAME": pending.username,
                pending.method.responseCodeKey: code,
            ],
        ]
        // A wrong code surfaces as CodeMismatchException from `call`;
        // Cognito keeps the challenge session valid for a bounded number
        // of retries, so `pendingChallenge` is kept until success.
        let response = try await call("RespondToAuthChallenge", body: body)
        let tokens = try parseAuthResult(response)
        try complete(tokens: tokens, username: pending.username, password: pending.password)
        pendingChallenge = nil
    }

    public func totpEnabled() async throws -> Bool {
        let response = try await call("GetUser", body: [
            "AccessToken": try await currentAccessToken(),
        ])
        let settings = response["UserMFASettingList"] as? [String] ?? []
        return settings.contains("SOFTWARE_TOKEN_MFA")
    }

    public func beginTotpEnrollment() async throws -> String {
        let response = try await call("AssociateSoftwareToken", body: [
            "AccessToken": try await currentAccessToken(),
        ])
        guard let secret = response["SecretCode"] as? String else {
            throw CabalmailError.decoding("Missing SecretCode")
        }
        return secret
    }

    public func confirmTotpEnrollment(code: String) async throws {
        let token = try await currentAccessToken()
        let verify = try await call("VerifySoftwareToken", body: [
            "AccessToken": token,
            "UserCode": code,
            "FriendlyDeviceName": "Cabalmail",
        ])
        guard (verify["Status"] as? String) == "SUCCESS" else {
            throw CabalmailError.protocolError("Software token verification did not succeed")
        }
        // Verified tokens are inert until the preference marks TOTP as the
        // user's factor; without this no sign-in is ever challenged.
        _ = try await call("SetUserMFAPreference", body: [
            "AccessToken": token,
            "SoftwareTokenMfaSettings": [
                "Enabled": true,
                "PreferredMfa": true,
            ],
        ])
    }

    public func disableTotp() async throws {
        _ = try await call("SetUserMFAPreference", body: [
            "AccessToken": try await currentAccessToken(),
            "SoftwareTokenMfaSettings": [
                "Enabled": false,
                "PreferredMfa": false,
            ],
        ])
    }

    /// Access-token twin of `currentIdToken()` — the user-attribute and MFA
    /// APIs (GetUser, AssociateSoftwareToken, ...) authenticate with the
    /// access token, not the ID token.
    private func currentAccessToken() async throws -> String {
        guard let tokens = try loadTokens() else {
            throw CabalmailError.notSignedIn
        }
        if !tokens.isExpired(now: clock()) {
            return tokens.accessToken
        }
        let refreshed = try await refresh(using: tokens)
        try persist(tokens: refreshed)
        return refreshed.accessToken
    }
}

extension CognitoAuthService {
    /// Cognito reports a Lambda-trigger rejection as
    /// "<TriggerName> failed with error <trigger message>." — the wrapper
    /// leaks the trigger's name and, when the trigger message has its own
    /// terminal period, produces a doubled one. Return just the trigger's
    /// message. Internal (not private) for direct unit coverage.
    static func stripLambdaTriggerWrapper(from message: String) -> String {
        var text = message
        if let range = text.range(of: " failed with error ") {
            // Only strip when the lead-in is a bare trigger name; a space
            // means the phrase occurs mid-sentence in a real message.
            let lead = text[..<range.lowerBound]
            if !lead.isEmpty && !lead.contains(" ") {
                text = String(text[range.upperBound...])
            }
        }
        while text.hasSuffix("..") {
            text.removeLast()
        }
        return text
    }
}
