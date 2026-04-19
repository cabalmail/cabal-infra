import XCTest
@testable import CabalmailKit

final class CabalmailKitTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(CabalmailKit.version.isEmpty)
    }

    func testConfigurationDecodesConfigJsonShape() throws {
        // Matches the real shape emitted by
        // terraform/infra/modules/app/templates/config.js (which is valid
        // JSON) and the config.json sibling. `domains` is an array of
        // Route 53 hosted-zone records, not a plain string list.
        let json = Data("""
        {
          "control_domain": "example.com",
          "domains": [
            {
              "arn": "arn:aws:route53:::hostedzone/Z1",
              "domain": "example.com",
              "name_servers": ["ns-1.awsdns-0.net"],
              "zone_id": "Z1"
            },
            {
              "arn": "arn:aws:route53:::hostedzone/Z2",
              "domain": "example.net",
              "name_servers": ["ns-2.awsdns-0.net"],
              "zone_id": "Z2"
            }
          ],
          "invokeUrl": "https://api.example.com/prod",
          "cognitoConfig": {
            "region": "us-east-1",
            "poolData": {
              "UserPoolId": "us-east-1_ABC",
              "ClientId": "xyz"
            }
          }
        }
        """.utf8)

        let config = try JSONDecoder().decode(Configuration.self, from: json)

        XCTAssertEqual(config.controlDomain, "example.com")
        XCTAssertEqual(config.domains.map(\.domain), ["example.com", "example.net"])
        XCTAssertEqual(config.domains.first?.zoneId, "Z1")
        XCTAssertEqual(config.invokeUrl.absoluteString, "https://api.example.com/prod")
        XCTAssertEqual(config.cognito.region, "us-east-1")
        XCTAssertEqual(config.cognito.userPoolId, "us-east-1_ABC")
        XCTAssertEqual(config.cognito.clientId, "xyz")
    }

    func testClientRoundTripsConfiguration() async throws {
        let config = Configuration(
            controlDomain: "example.com",
            domains: [MailDomain(domain: "example.com")],
            invokeUrl: URL(string: "https://api.example.com/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
        let auth = StubAuthService()
        let api = URLSessionApiClient(
            configuration: config,
            authService: auth,
            transport: RecordingHTTPTransport(responses: [])
        )
        let imap = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let smtp = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let envelopes = try EnvelopeCache(directory: tmp.appendingPathComponent("e"))
        let bodies = try MessageBodyCache(directory: tmp.appendingPathComponent("b"))
        let client = CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: api,
            imapClient: imap,
            smtpClient: smtp,
            addressCache: AddressCache(),
            envelopeCache: envelopes,
            bodyCache: bodies
        )
        let roundTrip = await client.configuration
        XCTAssertEqual(roundTrip, config)
    }
}
