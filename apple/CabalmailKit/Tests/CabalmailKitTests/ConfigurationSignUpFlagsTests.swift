import XCTest
@testable import CabalmailKit

/// `invitation_required` and `sms_enabled` decide which fields the sign-up
/// screens show. They read as the webmail reads them (`App.jsx`), and a
/// file or cached copy without them still decodes (auth parity plan, B1).
final class ConfigurationSignUpFlagsTests: XCTestCase {
    private static func decode(flags: String) throws -> Configuration {
        let json = """
        {
          "control_domain": "example.com",
          "domains": [],
          "invokeUrl": "https://api.example.com/prod",
          \(flags)
          "cognitoConfig": {"region": "us-east-1", "poolData": {"UserPoolId": "p", "ClientId": "c"}}
        }
        """
        return try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    }

    func testTheFlagsAreRead() throws {
        let gated = try Self.decode(flags: #""invitation_required": true, "sms_enabled": false,"#)
        XCTAssertTrue(gated.invitationRequired)
        XCTAssertFalse(gated.smsEnabled)

        let open = try Self.decode(flags: #""invitation_required": false, "sms_enabled": true,"#)
        XCTAssertFalse(open.invitationRequired)
        XCTAssertTrue(open.smsEnabled)
    }

    /// An older file: no invitation field, and the phone field kept.
    func testMissingFlagsTakeTheWebmailsDefaults() throws {
        let config = try Self.decode(flags: "")
        XCTAssertFalse(config.invitationRequired)
        XCTAssertTrue(config.smsEnabled)
    }

    /// A flag of the wrong type must not cost the user the sign-in form.
    func testAMalformedFlagDoesNotFailTheFile() throws {
        let config = try Self.decode(flags: #""invitation_required": "yes", "sms_enabled": 0,"#)
        XCTAssertFalse(config.invitationRequired)
        XCTAssertTrue(config.smsEnabled)
    }

    /// `ConfigurationCache` stores the encoded struct, so the flags have to
    /// come back from it.
    func testTheFlagsSurviveTheCacheRoundTrip() throws {
        let config = Configuration(
            controlDomain: "example.com",
            domains: [],
            invokeUrl: URL(string: "https://api.example.com/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "p", clientId: "c"),
            invitationRequired: true,
            smsEnabled: false
        )
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }
}
