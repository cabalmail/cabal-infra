import Foundation

/// Shared-container handoff to the Notification Service Extension (NSE).
///
/// The NSE enriches the wake-signal push ("New mail") by calling
/// `/push_envelope`, so it needs the API Gateway URL and a valid Cognito ID
/// token — but it deliberately does **not** link CabalmailKit (the extension
/// stays tiny; see `apple/CabalmailNotificationService/`). This type is the
/// writer half of that contract: the main app mirrors
///
/// - `Configuration.invokeUrl` into the App Group `UserDefaults`, and
/// - the current ID token + expiry into a keychain item in the shared
///   access group (`<TEAMID>.com.cabalmail.shared`),
///
/// and the NSE reads both back with its own local `UserDefaults` /
/// `SecItem` helpers.
///
/// Every write is best-effort and never throws: simulator and unsigned
/// builds lack the app-group / keychain-sharing entitlements (SecItem fails
/// with errSecMissingEntitlement, surfaced by `KeychainSecureStore` as a
/// thrown error we swallow here), and a missing mirror only costs
/// notification enrichment — it must never break sign-in.
public struct PushEnrichmentStore: @unchecked Sendable {
    /// App Group shared between the app and the NSE. Declared in both
    /// targets' entitlements files.
    public static let appGroupID = "group.com.cabalmail.Cabalmail"
    /// Unprefixed shared keychain access group. The runtime SecItem calls
    /// need the fully-qualified `<TEAMID>.` form — see `resolvedAccessGroup`.
    public static let keychainAccessGroupSuffix = "com.cabalmail.shared"
    /// App Group `UserDefaults` key carrying the API Gateway stage URL.
    public static let apiURLDefaultsKey = "cabal.push.api_url"
    /// Keychain coordinates of the mirrored token JSON (`tokenPayload`).
    public static let keychainService = "com.cabalmail.push"
    public static let keychainAccount = "push.auth"

    // Nil when the shared containers can't exist in this context (no team-ID
    // prefix in Info.plist, e.g. unsigned builds or the test runner); every
    // operation degrades to a no-op. `UserDefaults` is documented
    // thread-safe, hence the `@unchecked Sendable` above.
    private let secureStore: SecureStore?
    private let defaults: UserDefaults?

    /// Production initializer: shared-group keychain + App Group defaults.
    public init() {
        if let group = Self.resolvedAccessGroup() {
            self.secureStore = KeychainSecureStore(
                service: Self.keychainService,
                accessGroup: group
            )
        } else {
            self.secureStore = nil
        }
        self.defaults = UserDefaults(suiteName: Self.appGroupID)
    }

    /// Injection point for tests.
    init(secureStore: SecureStore?, defaults: UserDefaults?) {
        self.secureStore = secureStore
        self.defaults = defaults
    }

    /// Fully-qualified shared access group (`<TEAMID>.com.cabalmail.shared`),
    /// or nil when the team-ID prefix isn't available. The prefix comes from
    /// the Info.plist `AppIdentifierPrefix` key, which project.yml routes
    /// through the same-named build setting — SecItem needs the literal
    /// prefixed group; the entitlement's `$(AppIdentifierPrefix)` shorthand
    /// is resolved at signing time only.
    static func resolvedAccessGroup() -> String? {
        guard
            let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
            !prefix.isEmpty
        else { return nil }
        return prefix + keychainAccessGroupSuffix
    }

    /// Mirrors the API Gateway URL. Called when a session is wired (sign-in
    /// or launch restore); the value only changes with the control domain,
    /// so overwriting on every session is harmlessly idempotent.
    public func updateAPIURL(_ url: URL) {
        defaults?.set(url.absoluteString, forKey: Self.apiURLDefaultsKey)
    }

    /// Mirrors a fresh ID token + expiry for the NSE to attach to
    /// `/push_envelope`. Best-effort — see the type comment.
    public func updateToken(idToken: String, expiresAt: Date) {
        guard let secureStore else { return }
        let payload = PushTokenPayload(idToken: idToken, expiresAt: expiresAt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? secureStore.set(data, forKey: Self.keychainAccount)
    }

    /// Convenience for the mirroring store: decodes the `AuthTokens` blob
    /// `CognitoAuthService` persists and mirrors just the ID-token half.
    /// A payload that doesn't decode is silently ignored.
    public func updateToken(fromEncodedAuthTokens data: Data) {
        guard let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data) else { return }
        updateToken(idToken: tokens.idToken, expiresAt: tokens.expiresAt)
    }

    /// Drops both mirrored values. Called on sign-out so a signed-out (or
    /// switched) device can't keep enriching notifications with the previous
    /// user's token.
    public func clear() {
        defaults?.removeObject(forKey: Self.apiURLDefaultsKey)
        try? secureStore?.remove(Self.keychainAccount)
    }
}

/// JSON payload stored under `PushEnrichmentStore.keychainAccount`.
/// snake_case to match the hand-rolled decoder in the NSE (which has no
/// shared type to import — keep in sync with
/// `apple/CabalmailNotificationService/NotificationService.swift`).
struct PushTokenPayload: Codable {
    let idToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case expiresAt = "expires_at"
    }
}

/// `SecureStore` decorator that mirrors Cognito token writes into the shared
/// push-enrichment containers.
///
/// `CognitoAuthService` persists every sign-in *and every silent refresh*
/// through its `SecureStore` under `SecureStoreKey.authTokens`; wrapping the
/// store hooks exactly that point, so the NSE's copy of the ID token can
/// never go stale relative to the app's without touching the auth service
/// itself. The base write is the source of truth: it runs first and its
/// errors propagate, while mirror failures are swallowed inside
/// `PushEnrichmentStore`.
public struct PushMirroringSecureStore: SecureStore {
    private let base: SecureStore
    private let mirror: PushEnrichmentStore

    public init(base: SecureStore, mirror: PushEnrichmentStore = PushEnrichmentStore()) {
        self.base = base
        self.mirror = mirror
    }

    public func set(_ value: Data, forKey key: String) throws {
        try base.set(value, forKey: key)
        if key == SecureStoreKey.authTokens {
            mirror.updateToken(fromEncodedAuthTokens: value)
        }
    }

    public func get(_ key: String) throws -> Data? {
        try base.get(key)
    }

    public func remove(_ key: String) throws {
        try base.remove(key)
        if key == SecureStoreKey.authTokens {
            mirror.clear()
        }
    }
}
