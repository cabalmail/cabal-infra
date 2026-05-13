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

    func testListAddressesDecodesFavoriteFlag() async throws {
        // The `/list` Lambda flattens a per-caller `favorite` boolean onto
        // each row (derived from the `favorites` string set). Older rows and
        // older deployments omit the field; decoding must default it to
        // false rather than throw.
        let body = """
        {
          "Items": [
            {"address":"alice@mail.example.com","subdomain":"mail","tld":"example.com","favorite":true},
            {"address":"bob@x.example.com","subdomain":"x","tld":"example.com","favorite":false},
            {"address":"carol@y.example.com","subdomain":"y","tld":"example.com"}
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
        XCTAssertEqual(addresses.map(\.favorite), [true, false, false])
    }

    func testSetFavoritePutsExpectedBody() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"address":"a","favorite":true}"#.utf8), 200)])
        let client = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await client.setFavorite(address: "alice@mail.example.com", favorite: true)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/set_favorite"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "idtoken")
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["address"] as? String, "alice@mail.example.com")
        XCTAssertEqual(payload?["favorite"] as? Bool, true)
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

    func testRequestAttachmentUploadsRoundTripsLambdaPayload() async throws {
        let body = #"""
            {"uploads":[
                {"key":"outbound/alice/uuid-a/a.txt","url":"https://s3.example.com/put-a"},
                {"key":"outbound/alice/uuid-b/b.bin","url":"https://s3.example.com/put-b"}
            ]}
        """#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let uploads = try await api.requestAttachmentUploads(
            host: "imap.example.com",
            files: [
                AttachmentUploadSlot(filename: "a.txt", mimeType: "text/plain"),
                AttachmentUploadSlot(filename: "b.bin", mimeType: "application/octet-stream"),
            ]
        )
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0].key, "outbound/alice/uuid-a/a.txt")
        XCTAssertEqual(uploads[0].url.absoluteString, "https://s3.example.com/put-a")
        XCTAssertEqual(uploads[1].key, "outbound/alice/uuid-b/b.bin")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/upload_url"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["host"] as? String, "imap.example.com")
        let files = payload?["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 2)
        XCTAssertEqual(files?[0]["filename"] as? String, "a.txt")
        XCTAssertEqual(files?[0]["mime_type"] as? String, "text/plain")
    }

    func testUploadAttachmentPUTsRawBytesToPresignedURL() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let bytes = Data("hello".utf8)
        try await api.uploadAttachment(
            url: URL(string: "https://s3.example.com/put-here")!,
            mimeType: "text/plain",
            data: bytes
        )
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://s3.example.com/put-here")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertEqual(request.httpBody, bytes)
        // Presigned URLs already carry credentials; ensure we did not add a
        // Bearer token (which S3 rejects alongside a signed URL).
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
