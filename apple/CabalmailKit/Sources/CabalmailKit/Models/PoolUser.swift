import Foundation

/// A user of the Cognito pool, as an administrator sees it in the Users view.
///
/// Mirrors one entry of `/list_users`' `Users` array
/// (`lambda/api/list_users/function.py`): `username`, the Cognito
/// `UserStatus`, `enabled`, `created` (Python `isoformat()`, with or without
/// fractional seconds) and `osid` (empty until the post-confirmation trigger
/// assigns one).
public struct PoolUser: Sendable, Hashable, Identifiable {
    public let username: String
    /// Cognito's `UserStatus`: `CONFIRMED`, `UNCONFIRMED`,
    /// `FORCE_CHANGE_PASSWORD`, and so on.
    public let status: String
    public let enabled: Bool
    public let created: Date?
    /// The mail-system user ID, or nil before one is assigned.
    public let osid: String?

    public var id: String { username }

    /// Not yet confirmed: anything but `CONFIRMED`, as the webmail's Users
    /// view groups them. An admin can confirm such an account.
    public var isPending: Bool { status != "CONFIRMED" }

    public init(username: String, status: String, enabled: Bool, created: Date? = nil, osid: String? = nil) {
        self.username = username
        self.status = status
        self.enabled = enabled
        self.created = created
        self.osid = osid
    }
}

extension PoolUser: Decodable {
    private enum CodingKeys: String, CodingKey {
        case username, status, enabled, created, osid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        created = try container.decodeIfPresent(String.self, forKey: .created).flatMap(Self.parseCreated)
        let osid = try container.decodeIfPresent(String.self, forKey: .osid)
        self.osid = osid?.isEmpty == false ? osid : nil
    }

    /// Python's `isoformat()` writes microseconds when there are any and
    /// none otherwise (`2024-01-02T03:04:05.123456+00:00`,
    /// `2024-01-02T03:04:05+00:00`). The fractional part is dropped before
    /// parsing: a creation date needs no finer than seconds, and
    /// `ISO8601DateFormatter`'s fractional-seconds option is pickier about
    /// digit counts than the rest of the format.
    static func parseCreated(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)
    }
}

/// One row of the per-user domain allow list (`cabal-user-domain-access`):
/// `user` may create addresses on `domain`. No row means no access, so a new
/// account can create no addresses until an admin grants it a domain.
public struct DomainAllowance: Sendable, Hashable, Decodable {
    public let user: String
    public let domain: String

    public init(user: String, domain: String) {
        self.user = user
        self.domain = domain
    }
}
