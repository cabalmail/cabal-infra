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

    public var id: String { address }

    public init(
        address: String,
        subdomain: String,
        tld: String,
        comment: String? = nil,
        publicKey: String? = nil
    ) {
        self.address = address
        self.subdomain = subdomain
        self.tld = tld
        self.comment = comment
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case subdomain
        case tld
        case comment
        case publicKey = "public_key"
    }
}
