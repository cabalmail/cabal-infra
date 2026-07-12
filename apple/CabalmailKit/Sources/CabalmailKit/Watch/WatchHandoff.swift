import Foundation

/// Credential hand-off from the iPhone app to its paired watch app.
///
/// The iPhone and the watch are separate devices with separate keychains, so
/// the watch cannot read the phone's Cognito session — it has to be handed
/// one. The phone encodes a `WatchHandoff` into the WatchConnectivity
/// application context (latest-state semantics: delivered whenever the watch
/// next wakes, surviving both apps being dead); the watch decodes it, adopts
/// the tokens into its own keychain via `CognitoAuthService.adopt`, and from
/// then on refreshes ID tokens autonomously for the refresh token's lifetime.
///
/// The user's password is deliberately NOT part of the hand-off. When the
/// refresh token expires the watch shows a "reconnect from your iPhone"
/// state rather than re-authenticating itself.
///
/// This type is pure Foundation (no WatchConnectivity import) so the codec
/// is exercised by `swift test` on any platform; the session plumbing that
/// actually ships the dictionary lives in the app targets.
public struct WatchHandoff: Sendable, Codable, Equatable {
    public let configuration: Configuration
    public let tokens: AuthTokens
    public let username: String

    public init(configuration: Configuration, tokens: AuthTokens, username: String) {
        self.configuration = configuration
        self.tokens = tokens
        self.username = username
    }
}

public extension WatchHandoff {
    /// Keys inside the WCSession application-context dictionary. The version
    /// gates decoding: a watch app older or newer than the phone app ignores
    /// contexts it doesn't understand instead of mis-decoding them.
    static let contextVersionKey = "cabalmail.handoff.version"
    static let contextPayloadKey = "cabalmail.handoff.payload"
    static let contextVersion = 1

    /// Context announcing "signed out" — versioned but carrying no payload.
    /// Pushed by the phone on sign-out so the watch drops its credentials.
    static func signedOutContext() -> [String: Any] {
        [contextVersionKey: contextVersion]
    }

    /// Application-context encoding of this hand-off. The payload rides as a
    /// single JSON `Data` value because WCSession dictionaries are limited to
    /// property-list types.
    func applicationContext() throws -> [String: Any] {
        [
            Self.contextVersionKey: Self.contextVersion,
            Self.contextPayloadKey: try JSONEncoder().encode(self),
        ]
    }

    /// Decodes a received application context. Returns nil for a version
    /// mismatch, a missing payload (the signed-out context), or a payload
    /// that fails to decode — callers distinguish "signed out" from "not a
    /// hand-off at all" with `isSignedOut(applicationContext:)`.
    static func from(applicationContext context: [String: Any]) -> WatchHandoff? {
        guard
            context[contextVersionKey] as? Int == contextVersion,
            let data = context[contextPayloadKey] as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(WatchHandoff.self, from: data)
    }

    /// True when the context is a versioned hand-off that explicitly carries
    /// no session — the phone's sign-out signal.
    static func isSignedOut(applicationContext context: [String: Any]) -> Bool {
        context[contextVersionKey] as? Int == contextVersion
            && context[contextPayloadKey] == nil
    }
}
