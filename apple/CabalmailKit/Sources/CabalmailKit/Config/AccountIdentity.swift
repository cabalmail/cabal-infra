import Foundation

/// Which account a session is for: the server it signs in to and the
/// username on it. One install holds one signed-in account at a time
/// (`docs/apple.md`, "One account per install"), and this is the one rule
/// for whether two sign-ins are for the same one.
///
/// - The server is compared normalized: trimmed, lowercased, and without a
///   leading `https://` or `http://`. The same server retyped with a
///   scheme, spaces or capitals is the same server; the sign-in form
///   remembers the field as typed, and `ConfigLoader` strips the same
///   things before it fetches.
/// - The username is compared exactly as typed. The user pool's usernames
///   are case-sensitive, so "Alice" and "alice" are two accounts, and their
///   cached mail is kept apart.
///
/// Anything that separates one account's local data from another's asks
/// here, so the rules cannot drift apart: the sign-in that decides whether
/// the cache on disk belongs to someone else, and the name of an account's
/// directory. (`Preferences.scopeIdentifier` is older and lowercases the
/// username; it keeps its own key so stored settings are not orphaned.)
public struct AccountIdentity: Hashable, Sendable {
    /// The control domain, normalized (`normalizedServer(_:)`).
    public let server: String
    /// The username exactly as typed.
    public let username: String

    /// `nil` when there is no username: nothing remembered is no account.
    public init?(controlDomain: String, username: String) {
        guard !username.isEmpty else { return nil }
        self.server = Self.normalizedServer(controlDomain)
        self.username = username
    }

    /// A control domain as it is compared: trimmed, lowercased, and without
    /// a leading `https://` or `http://`.
    public static func normalizedServer(_ controlDomain: String) -> String {
        var server = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if server.hasPrefix("https://") {
            server.removeFirst("https://".count)
        } else if server.hasPrefix("http://") {
            server.removeFirst("http://".count)
        }
        return server.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
