import Foundation

/// Runtime configuration for the Apple client.
///
/// Mirrors the JSON shape emitted by the Terraform-managed `config.json` object
/// served from the control-domain CloudFront distribution (see
/// `terraform/infra/modules/app/s3.tf`). The same object also backs the React
/// app's `config.js` — they are sibling representations of the same values.
public struct Configuration: Sendable, Codable, Equatable {
    public let controlDomain: String
    public let domains: [String]
    public let invokeUrl: URL
    public let cognito: CognitoConfiguration

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

        private struct PoolData: Codable {
            let UserPoolId: String
            let ClientId: String
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.region = try container.decode(String.self, forKey: .region)
            let pool = try container.decode(PoolData.self, forKey: .poolData)
            self.userPoolId = pool.UserPoolId
            self.clientId = pool.ClientId
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(region, forKey: .region)
            try container.encode(
                PoolData(UserPoolId: userPoolId, ClientId: clientId),
                forKey: .poolData
            )
        }
    }

    public init(
        controlDomain: String,
        domains: [String],
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
}
