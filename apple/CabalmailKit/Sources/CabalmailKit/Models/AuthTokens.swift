import Foundation

/// Cognito `AuthenticationResult` bundle, plus a computed absolute expiry.
///
/// The wire payload from `InitiateAuth` and `RespondToAuthChallenge` uses
/// `ExpiresIn` (seconds from now); the Apple client pins that to an absolute
/// `Date` at parse time so a cache hit from hours-later `currentIdToken()`
/// can decide cheaply whether to refresh.
public struct AuthTokens: Sendable, Codable, Hashable {
    public let idToken: String
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let expiresAt: Date

    public init(
        idToken: String,
        accessToken: String,
        refreshToken: String?,
        tokenType: String = "Bearer",
        expiresAt: Date
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
    }

    /// True if the ID token either has expired or is within `leeway` of expiry.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}
