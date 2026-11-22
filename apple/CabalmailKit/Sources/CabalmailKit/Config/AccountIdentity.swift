import CryptoKit
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

    /// The name of this account's directory under
    /// `Application Support/Cabalmail/accounts/` (`AccountDirectory`): the
    /// SHA-256 of the normalized server and the username as typed, as 64
    /// lowercase hex digits.
    ///
    /// A digest, not the username itself, so the name is the same length for
    /// every account, holds no character a file system refuses, and keeps
    /// two usernames that differ only by case apart on the Mac's
    /// case-insensitive disk, where "Alice" and "alice" would be one
    /// directory. Two identities that compare equal get one name: both parts
    /// are hashed in their canonical composed form, because `==` on a
    /// `String` already treats the composed and decomposed spellings of a
    /// letter as equal. The server's length goes in front so that no two
    /// (server, username) pairs spell the same input.
    ///
    /// The name is on disk in every install, so it must not change between
    /// releases: `AccountDirectoryTests` pins one.
    public var directoryName: String {
        let server = self.server.precomposedStringWithCanonicalMapping
        let username = self.username.precomposedStringWithCanonicalMapping
        let input = Data("\(server.utf8.count):\(server)\(username)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
