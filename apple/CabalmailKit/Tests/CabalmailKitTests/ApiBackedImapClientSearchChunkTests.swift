import XCTest
@testable import CabalmailKit

// Coverage for the bounded-batch envelope fetch (Layer 3.2) and the
// concurrent multi-flag fan-out (Layer 3.5). Kept in its own file so the
// primary `ApiBackedImapClientTests` stays under SwiftLint's file/type caps.
final class ApiBackedImapClientSearchChunkTests: XCTestCase {

    // MARK: - searchEnvelopesChunked (Layer 3.2)
    //
    // The helper lives on `ImapClient` and walks the `/search_envelopes`
    // cursor; these tests drive it through the API-backed client and the
    // recording transport so the per-page wire shape (limit + cursor) is
    // exercised end to end.

    func testWalksCursorUntilExhausted() async throws {
        let http = RecordingHTTPTransport(responses: [
            (Data(searchPageBody(ids: [9, 8], nextCursor: "c1").utf8), 200),
            (Data(searchPageBody(ids: [7], nextCursor: nil).utf8), 200),
        ])
        let client = makeClient(http)
        let result = try await client.searchEnvelopesChunked(
            SearchQuery(folder: "INBOX", text: "hello"),
            pageSize: 2,
            maxResults: 10
        )
        XCTAssertEqual(result.envelopes.map(\.envelope.uid), [9, 8, 7])
        XCTAssertNil(result.nextCursor, "exhausted set leaves no cursor")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalEstimate, 137, "total comes from the first page")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("limit=2"))
        XCTAssertFalse(requests[0].url!.absoluteString.contains("cursor="),
                       "first page sends no cursor")
        XCTAssertTrue(requests[1].url!.absoluteString.contains("cursor=c1"))
        XCTAssertTrue(requests[1].url!.absoluteString.contains("limit=2"))
    }

    func testStopsAtMaxResults() async throws {
        // Only one page is scripted: a second request would throw "ran out of
        // responses", so this also proves the walk halts at the cap.
        let http = RecordingHTTPTransport(responses: [
            (Data(searchPageBody(ids: [9, 8], nextCursor: "c1").utf8), 200),
        ])
        let client = makeClient(http)
        let result = try await client.searchEnvelopesChunked(
            SearchQuery(folder: "INBOX", text: "hello"),
            pageSize: 2,
            maxResults: 2
        )
        XCTAssertEqual(result.envelopes.map(\.envelope.uid), [9, 8])
        XCTAssertEqual(result.nextCursor, "c1", "more pages remain past the cap")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testShrinksFinalPageLimit() async throws {
        // pageSize 2, cap 5: the last request must ask for only `5 - 4 = 1`.
        let http = RecordingHTTPTransport(responses: [
            (Data(searchPageBody(ids: [9, 8], nextCursor: "c1").utf8), 200),
            (Data(searchPageBody(ids: [7, 6], nextCursor: "c2").utf8), 200),
            (Data(searchPageBody(ids: [5], nextCursor: nil).utf8), 200),
        ])
        let client = makeClient(http)
        let result = try await client.searchEnvelopesChunked(
            SearchQuery(folder: "INBOX", text: "hello"),
            pageSize: 2,
            maxResults: 5
        )
        XCTAssertEqual(result.envelopes.map(\.envelope.uid), [9, 8, 7, 6, 5])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("limit=2"))
        XCTAssertTrue(requests[1].url!.absoluteString.contains("limit=2"))
        XCTAssertTrue(requests[2].url!.absoluteString.contains("limit=1"))
        XCTAssertTrue(requests[2].url!.absoluteString.contains("cursor=c2"))
    }

    func testUnionsTruncatedFlag() async throws {
        // A later page reporting the server's budget-truncation flag must
        // surface in the merged result even though the first page was clean.
        let http = RecordingHTTPTransport(responses: [
            (Data(searchPageBody(ids: [9, 8], nextCursor: "c1").utf8), 200),
            (Data(searchPageBody(ids: [7], nextCursor: nil, truncated: true).utf8), 200),
        ])
        let client = makeClient(http)
        let result = try await client.searchEnvelopesChunked(
            SearchQuery(folder: "INBOX", text: "hello"),
            pageSize: 2,
            maxResults: 10
        )
        XCTAssertTrue(result.truncated)
    }

    func testStopsOnEmptyPage() async throws {
        // A page that returns nothing but still hands back a cursor must not
        // spin forever -- the walk breaks and reports what it has.
        let http = RecordingHTTPTransport(responses: [
            (Data(searchPageBody(ids: [9], nextCursor: "c1").utf8), 200),
            (Data(searchPageBody(ids: [], nextCursor: "c2").utf8), 200),
        ])
        let client = makeClient(http)
        let result = try await client.searchEnvelopesChunked(
            SearchQuery(folder: "INBOX", text: "hello"),
            pageSize: 2,
            maxResults: 10
        )
        XCTAssertEqual(result.envelopes.map(\.envelope.uid), [9])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2, "stops after the empty page")
    }

    // MARK: - setFlags fan-out (Layer 3.5)

    func testSetFlagsCoversEveryFlagExactlyOnce() async throws {
        // Concurrency must not drop or duplicate a flag: a two-flag toggle
        // issues exactly one `/set_flag` per distinct flag.
        let ok = #"{"message_ids":[]}"#
        let http = RecordingHTTPTransport(responses: [
            (Data(ok.utf8), 200),
            (Data(ok.utf8), 200),
        ])
        let client = makeClient(http)
        try await client.setFlags(
            folder: "INBOX",
            uids: [1, 2],
            flags: [.seen, .flagged],
            operation: .add
        )
        let requests = await http.requests
        let flags = Set(requests.map { request -> String in
            let json = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
            let payload = json as? [String: Any]
            return payload?["flag"] as? String ?? ""
        })
        XCTAssertEqual(flags, ["\\Seen", "\\Flagged"])
    }

    func testSetFlagsWithNoFlagsHitsNoEndpoint() async throws {
        let http = RecordingHTTPTransport(responses: [])
        let client = makeClient(http)
        try await client.setFlags(folder: "INBOX", uids: [1], flags: [], operation: .add)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 0, "an empty flag set should not hit the wire")
    }

    // MARK: - Helpers

    private func makeClient(_ http: RecordingHTTPTransport) -> ApiBackedImapClient {
        let api = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: http
        )
        return ApiBackedImapClient(api: api, host: "imap.example.com")
    }

    private func searchPageBody(ids: [Int], nextCursor: String?, truncated: Bool = false) -> String {
        let envs = ids.map { id in
            """
            {"id": \(id), "date": "2024-03-01 09:00:00+00:00", "subject": "s\(id)",
             "from": ["a@x.com"], "to": [], "cc": [], "flags": [],
             "struct": null, "folder": "INBOX"}
            """
        }.joined(separator: ",")
        let cursorField = nextCursor.map { "\"\($0)\"" } ?? "null"
        return """
        {"envelopes": [\(envs)], "total_estimate": 137,
         "next_cursor": \(cursorField), "folders_searched": ["INBOX"],
         "truncated": \(truncated)}
        """
    }
}
