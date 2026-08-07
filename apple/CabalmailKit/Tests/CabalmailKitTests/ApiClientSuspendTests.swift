import XCTest
@testable import CabalmailKit

/// Wire-level tests for `/suspend_address` and `/reinstate_address`, plus the
/// `suspended` field on the `/list` row shape. Suspension withdraws an
/// address's DNS records server-side while keeping the address itself, so the
/// client contract is just "PUT the address" and a boolean on the list row.
final class ApiClientSuspendTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testSuspendAddressPutsAddressBody() async throws {
        let body = #"{"status":"success","address":"a@b.cabalmail.example","suspended":true}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.suspendAddress(address: "a@b.cabalmail.example")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.hasSuffix("/suspend_address"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "idtoken")
        let sent = try XCTUnwrap(requests[0].httpBody)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent) as? [String: String]
        )
        XCTAssertEqual(decoded, ["address": "a@b.cabalmail.example"])
    }

    func testReinstateAddressPutsAddressBody() async throws {
        let body = #"{"status":"success","address":"a@b.cabalmail.example","suspended":false}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.reinstateAddress(address: "a@b.cabalmail.example")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.hasSuffix("/reinstate_address"))
        let sent = try XCTUnwrap(requests[0].httpBody)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sent) as? [String: String]
        )
        XCTAssertEqual(decoded, ["address": "a@b.cabalmail.example"])
    }

    func testListAddressesDecodesSuspendedFlag() async throws {
        // Row shape from `lambda/api/list/function.py` after the suspend
        // feature: `suspended` is always present. Older deployments omit it,
        // which must decode as false.
        let body = #"""
        {"Items":[
          {"address":"a@b.cabalmail.example","subdomain":"b","tld":"cabalmail.example","suspended":true},
          {"address":"c@d.cabalmail.example","subdomain":"d","tld":"cabalmail.example"}
        ]}
        """#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let addresses = try await client.listAddresses()
        XCTAssertEqual(addresses.count, 2)
        XCTAssertTrue(addresses[0].suspended)
        XCTAssertFalse(addresses[1].suspended)
    }
}
