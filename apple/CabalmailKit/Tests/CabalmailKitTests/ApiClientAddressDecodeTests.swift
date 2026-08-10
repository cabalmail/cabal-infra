import XCTest
@testable import CabalmailKit

/// Decode-robustness tests for the `/list` row shape, split out of
/// `ApiClientTests` to keep that class under SwiftLint's type_body_length cap.
final class ApiClientAddressDecodeTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    /// Addresses minted before the no-apex-addressing policy live on a mail
    /// domain's apex and carry no `subdomain` attribute at all, so the `/list`
    /// Lambda's projection omits the key. One such row must not fail the whole
    /// list (a prod user's reply composer showed "Couldn't load addresses"
    /// over exactly this).
    func testListAddressesToleratesLegacyApexRowWithoutSubdomain() async throws {
        let body = """
        {
          "Items": [
            {
              "address": "facebook@hackthumb.example",
              "tld": "hackthumb.example",
              "username": "facebook",
              "user": "jake"
            },
            {
              "address": "jake@vital.cabalmail.example",
              "subdomain": "vital",
              "tld": "cabalmail.example",
              "user": "jake"
            }
          ]
        }
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let addresses = try await client.listAddresses()
        XCTAssertEqual(addresses.map(\.address), [
            "facebook@hackthumb.example",
            "jake@vital.cabalmail.example",
        ])
        XCTAssertEqual(addresses.first?.subdomain, "")
    }

    /// When the payload matches none of the accepted shapes, the surfaced
    /// error must describe the `Items` decode (the real Lambda wire shape),
    /// not the last-resort `{"addresses": ...}` fallback — the latter is how
    /// a broken row used to masquerade as "key 'addresses' not found".
    func testUndecodableListSurfacesItemsShapeError() async throws {
        let body = #"{"Items": [{"address": 42}]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        do {
            _ = try await client.listAddresses()
            XCTFail("expected a decoding error")
        } catch let DecodingError.typeMismatch(_, context) {
            XCTAssertEqual(context.codingPath.first?.stringValue, "Items")
        }
    }
}
