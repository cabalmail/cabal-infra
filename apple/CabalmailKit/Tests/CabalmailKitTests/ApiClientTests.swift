import XCTest
@testable import CabalmailKit

final class ApiClientTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testListAddressesAttachesJWTAndDecodes() async throws {
        let body = """
        [
          {"address":"foo@example.com","subdomain":"mail","tld":"example.com"}
        ]
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let auth = StubAuthService()
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: auth,
            transport: http
        )

        let addresses = try await client.listAddresses()
        XCTAssertEqual(addresses.map(\.address), ["foo@example.com"])

        let requests = await http.requests
        let request = requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.cabalmail.example/prod/list")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "idtoken")
    }

    /// Real Lambda wire shape from `lambda/api/list/function.py`:
    /// `{"Items": [...]}`. This is what the compose view actually receives
    /// when seeding the From picker — keeping the test pinned to the exact
    /// Lambda output guards against regressions like the Phase 5 shipping
    /// bug where the compose sheet showed "Couldn't load addresses".
    func testListAddressesDecodesItemsWrapperFromLambda() async throws {
        let body = """
        {
          "Items": [
            {
              "address": "alice@mail.example.com",
              "subdomain": "mail",
              "tld": "example.com",
              "comment": "personal",
              "username": "alice",
              "user": "alice"
            },
            {
              "address": "bob@x.example.com",
              "subdomain": "x",
              "tld": "example.com",
              "username": "bob",
              "user": "bob"
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
            "alice@mail.example.com",
            "bob@x.example.com",
        ])
        XCTAssertEqual(addresses.first?.comment, "personal")
    }

    func testListAddressesRetriesOn401AndRefreshesToken() async throws {
        let body = "[]"
        let http = RecordingHTTPTransport(responses: [
            (Data("unauthorized".utf8), 401),
            (Data(body.utf8), 200),
        ])
        let auth = StubAuthService()
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: auth,
            transport: http
        )

        let addresses = try await client.listAddresses()
        XCTAssertTrue(addresses.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)

        let callCount = await auth.idTokenCallCount
        // One token fetch for the initial attach, one forced refresh after 401.
        XCTAssertEqual(callCount, 2)
    }

    func testSecondaryUnauthorizedSurfacesAsAuthExpired() async throws {
        let http = RecordingHTTPTransport(responses: [
            (Data("unauth".utf8), 401),
            (Data("unauth".utf8), 401),
        ])
        let auth = StubAuthService()
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: auth,
            transport: http
        )
        do {
            _ = try await client.listAddresses()
            XCTFail("Expected auth error")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired)
        }
    }

    func testFetchBimiReturnsNilWhenEmpty() async throws {
        let http = RecordingHTTPTransport(responses: [(Data("{}".utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let url = try await client.fetchBimiURL(senderDomain: "example.com")
        XCTAssertNil(url)
    }
}
