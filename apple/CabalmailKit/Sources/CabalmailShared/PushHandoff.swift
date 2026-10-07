import Foundation

/// Where the app leaves what the Notification Service Extensions need to
/// enrich a push: the API Gateway URL in the `AppGroup` defaults, and the
/// Cognito ID token in the shared keychain access group.
///
/// CabalmailKit's `PushEnrichmentStore` writes both, and
/// `apple/CabalmailNotificationService/NotificationService.swift` reads them
/// back with its own `UserDefaults` and `SecItem` calls. A wrong name on
/// either side doesn't fail anything at run time: every notification just
/// shows "New mail" again, which is why `PushHandoffContractTests` pins them.
public enum PushHandoff {
    /// `AppGroup` `UserDefaults` key carrying the API Gateway stage URL.
    public static let apiURLDefaultsKey = "cabal.push.api_url"
    /// Keychain service of the mirrored token item.
    public static let keychainService = "com.cabalmail.push"
    /// Keychain account of the mirrored token item; its data is a
    /// JSON-encoded `PushTokenPayload`.
    public static let keychainAccount = "push.auth"
    /// The shared keychain access group without its `<TEAMID>.` prefix.
    /// `SecItem` calls need the prefixed form, which exists only at run time
    /// (the entitlements' `$(AppIdentifierPrefix)` is resolved at signing).
    public static let keychainAccessGroupSuffix = "com.cabalmail.shared"
}

/// The mirrored ID token and its expiry, stored under
/// `PushHandoff.keychainAccount`. Both sides use a plain `JSONEncoder` /
/// `JSONDecoder`, so `expires_at` is Foundation's default date encoding:
/// seconds since 2001-01-01, as a JSON number.
public struct PushTokenPayload: Codable, Equatable, Sendable {
    public let idToken: String
    public let expiresAt: Date

    public init(idToken: String, expiresAt: Date) {
        self.idToken = idToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case expiresAt = "expires_at"
    }
}
