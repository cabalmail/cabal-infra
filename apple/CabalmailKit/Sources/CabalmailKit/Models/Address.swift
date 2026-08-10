import Foundation

/// A Cabalmail address owned by the signed-in user.
///
/// Mirrors the JSON shape returned by the `/list` Lambda (see
/// `lambda/api/list/function.py`). The Lambda returns a DynamoDB item flattened
/// to JSON; the fields below are the subset the Apple client relies on.
public struct Address: Sendable, Codable, Hashable, Identifiable {
    public let address: String
    public let subdomain: String
    public let tld: String
    public let comment: String?
    public let publicKey: String?
    /// Per-caller favorite flag derived from the `favorites` string set on the
    /// DynamoDB row (see `lambda/api/list/function.py`). Defaults to false when
    /// the field is absent — older Lambda deployments and locally-constructed
    /// values don't carry it.
    public var favorite: Bool
    /// True while the address is suspended: its DNS records are withdrawn so
    /// inbound mail stops resolving, but the address itself is retained and
    /// can be reinstated. Defaults to false when the field is absent — older
    /// Lambda deployments and locally-constructed values don't carry it.
    public var suspended: Bool

    public var id: String { address }

    public init(
        address: String,
        subdomain: String,
        tld: String,
        comment: String? = nil,
        publicKey: String? = nil,
        favorite: Bool = false,
        suspended: Bool = false
    ) {
        self.address = address
        self.subdomain = subdomain
        self.tld = tld
        self.comment = comment
        self.publicKey = publicKey
        self.favorite = favorite
        self.suspended = suspended
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case subdomain
        case tld
        case comment
        case publicKey = "public_key"
        case favorite
        case suspended
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.address = try container.decode(String.self, forKey: .address)
        // Rows minted before the no-apex-addressing policy (pre-2020) live
        // directly on a mail domain's apex and have no `subdomain` attribute
        // at all, so DynamoDB's projection omits the key. Treat absence as
        // empty rather than failing the whole list over one legacy row.
        self.subdomain = try container.decodeIfPresent(String.self, forKey: .subdomain) ?? ""
        self.tld = try container.decode(String.self, forKey: .tld)
        self.comment = try container.decodeIfPresent(String.self, forKey: .comment)
        self.publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        self.favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        self.suspended = try container.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
    }
}
