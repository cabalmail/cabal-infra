import XCTest
@testable import CabalmailKit

final class CabalmailKitTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(CabalmailKit.version.isEmpty)
    }

    func testConfigurationDecodesConfigJsonShape() throws {
        // Matches the shape emitted by terraform/infra/modules/app/templates/config.js
        // (which is valid JSON) and the new config.json sibling.
        let json = """
        {
          "control_domain": "example.com",
          "domains": ["example.com", "example.net"],
          "invokeUrl": "https://api.example.com/prod",
          "cognitoConfig": {
            "region": "us-east-1",
            "poolData": {
              "UserPoolId": "us-east-1_ABC",
              "ClientId": "xyz"
            }
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Configuration.self, from: json)

        XCTAssertEqual(config.controlDomain, "example.com")
        XCTAssertEqual(config.domains, ["example.com", "example.net"])
        XCTAssertEqual(config.invokeUrl.absoluteString, "https://api.example.com/prod")
        XCTAssertEqual(config.cognito.region, "us-east-1")
        XCTAssertEqual(config.cognito.userPoolId, "us-east-1_ABC")
        XCTAssertEqual(config.cognito.clientId, "xyz")
    }

    func testClientInitialization() async {
        let config = Configuration(
            controlDomain: "example.com",
            domains: ["example.com"],
            invokeUrl: URL(string: "https://api.example.com/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
        let client = CabalmailClient(configuration: config)
        let roundTrip = await client.configuration
        XCTAssertEqual(roundTrip, config)
    }
}
