import Foundation

/// Runtime configuration for the Apple client.
///
/// Mirrors the JSON shape emitted by the Terraform-managed `config.json` object
/// served from the control-domain CloudFront distribution (see
/// `terraform/infra/modules/app/s3.tf`). The same object also backs the React
/// app's `config.js` — they are sibling representations of the same values.
public struct Configuration: Sendable, Codable, Equatable {
    public let controlDomain: String
    public let domains: [MailDomain]
    public let invokeUrl: URL
    public let cognito: CognitoConfiguration

    public init(
        controlDomain: String,
        domains: [MailDomain],
        invokeUrl: URL,
        cognito: CognitoConfiguration
    ) {
        self.controlDomain = controlDomain
        self.domains = domains
        self.invokeUrl = invokeUrl
        self.cognito = cognito
    }

    private enum CodingKeys: String, CodingKey {
        case controlDomain = "control_domain"
        case domains
        case invokeUrl
        case cognito = "cognitoConfig"
    }

    /// IMAP hostname derived from the control domain.
    ///
    /// Mirrors the rule `react/admin/src/App.jsx` uses: a `dev.*` control
    /// domain swaps the `dev.` prefix for `imap.`, everything else gets
    /// `imap.` prepended. The resulting hostname is what the
    /// `terraform/infra/modules/elb` DNS records point at.
    public var imapHost: String {
        if controlDomain.hasPrefix("dev.") {
            return "imap." + controlDomain.dropFirst("dev.".count)
        }
        return "imap.\(controlDomain)"
    }

    /// Submission hostname — always `smtp-out.<control_domain>` per the
    /// same convention.
    public var smtpHost: String {
        "smtp-out.\(controlDomain)"
    }
}

/// One of the mail domains the Cabalmail deployment is authoritative for.
/// Phase 4 only reads `domain`; Phase 5's From-address picker uses it to
/// build subdomain choices. The remaining fields mirror the Route 53 hosted-
/// zone record Terraform writes into `config.json`.
public struct MailDomain: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let domain: String
    public let arn: String?
    public let zoneId: String?
    public let nameServers: [String]

    public var id: String { domain }

    public init(
        domain: String,
        arn: String? = nil,
        zoneId: String? = nil,
        nameServers: [String] = []
    ) {
        self.domain = domain
        self.arn = arn
        self.zoneId = zoneId
        self.nameServers = nameServers
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case arn
        case zoneId = "zone_id"
        case nameServers = "name_servers"
    }
}

/// Cognito portion of `Configuration`.
///
/// The JSON wire format nests the pool identifiers under a `poolData` object
/// whose keys use PascalCase (`UserPoolId`, `ClientId`) because that's what the
/// Cognito JS SDK consumes; the Swift surface normalizes those to idiomatic
/// camelCase properties via `CodingKeys`.
public struct CognitoConfiguration: Sendable, Codable, Equatable {
    public let region: String
    public let userPoolId: String
    public let clientId: String

    public init(region: String, userPoolId: String, clientId: String) {
        self.region = region
        self.userPoolId = userPoolId
        self.clientId = clientId
    }

    private enum CodingKeys: String, CodingKey {
        case region
        case poolData
    }

    private enum PoolKeys: String, CodingKey {
        case userPoolId = "UserPoolId"
        case clientId = "ClientId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.region = try container.decode(String.self, forKey: .region)
        let pool = try container.nestedContainer(keyedBy: PoolKeys.self, forKey: .poolData)
        self.userPoolId = try pool.decode(String.self, forKey: .userPoolId)
        self.clientId = try pool.decode(String.self, forKey: .clientId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(region, forKey: .region)
        var pool = container.nestedContainer(keyedBy: PoolKeys.self, forKey: .poolData)
        try pool.encode(userPoolId, forKey: .userPoolId)
        try pool.encode(clientId, forKey: .clientId)
    }
}
