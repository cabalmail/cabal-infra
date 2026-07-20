import XCTest
@testable import CabalmailKit

/// Wire-level tests for `/list_my_domains`, which the address-creation
/// picker (macOS/iOS/visionOS `NewAddressSheet`, watchOS `NewAddressView`)
/// uses to filter the configured mail domains down to what the caller is
/// entitled to mint on.
final class ApiClientDomainsTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testListMyDomainsDecodesLambdaEnvelope() async throws {
        // Real wire shape from `lambda/api/list_my_domains/function.py`:
        // `{"Domains": [<apex>...]}`.
        let body = #"{"Domains":["cabalmail.com","cabalmail.net"]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let allowed = try await client.listMyDomains()
        XCTAssertEqual(allowed, ["cabalmail.com", "cabalmail.net"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.absoluteString.hasSuffix("/list_my_domains"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    func testListMyDomainsDefaultsToEmptyWhenKeyMissing() async throws {
        // Guard the "partially-migrated deployment" case: a body without a
        // `Domains` key must read as "no entitled apexes", not an error.
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let allowed = try await client.listMyDomains()
        XCTAssertEqual(allowed, [])
    }
}
