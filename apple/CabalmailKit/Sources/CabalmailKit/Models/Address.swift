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

    public var id: String { address }

    public init(
        address: String,
        subdomain: String,
        tld: String,
        comment: String? = nil,
        publicKey: String? = nil,
        favorite: Bool = false
    ) {
        self.address = address
        self.subdomain = subdomain
        self.tld = tld
        self.comment = comment
        self.publicKey = publicKey
        self.favorite = favorite
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case subdomain
        case tld
        case comment
        case publicKey = "public_key"
        case favorite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.address = try c.decode(String.self, forKey: .address)
        self.subdomain = try c.decode(String.self, forKey: .subdomain)
        self.tld = try c.decode(String.self, forKey: .tld)
        self.comment = try c.decodeIfPresent(String.self, forKey: .comment)
        self.publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    }
}
