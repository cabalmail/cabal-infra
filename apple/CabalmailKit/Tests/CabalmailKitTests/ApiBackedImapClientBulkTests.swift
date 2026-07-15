import XCTest
@testable import CabalmailKit

// Coverage for Phase 4 of `docs/1.1.x/multi-select-bulk-operations.md`:
// client-side chunking of large bulk ops and partial-failure aggregation
// (`CabalmailError.bulkPartialFailure`). In its own file so the primary
// `ApiBackedImapClientTests` stays under SwiftLint's file/type caps.
final class ApiBackedImapClientBulkTests: XCTestCase {

    private let submitted = #"{"status":"submitted"}"#

    // MARK: - Chunking

    func testMoveChunksLargeSelections() async throws {
        // 2.5 chunks' worth of UIDs must fan into exactly three sequential
        // PUTs of 1000 / 1000 / 500 ids, all against /move_messages.
        let http = RecordingHTTPTransport(responses: [
            (Data(submitted.utf8), 200),
            (Data(submitted.utf8), 200),
            (Data(submitted.utf8), 200),
        ])
        let client = makeClient(http)
        let uids = Array(UInt32(1)...2500)
        try await client.move(folder: "INBOX", uids: uids, destination: "Archive")

        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        let idCounts = requests.map { requestIds($0).count }
        XCTAssertEqual(idCounts, [1000, 1000, 500])
        XCTAssertEqual(requestIds(requests[0]).first, 1)
        XCTAssertEqual(requestIds(requests[1]).first, 1001)
        XCTAssertEqual(requestIds(requests[2]).first, 2001)
        for request in requests {
            XCTAssertTrue(request.url!.absoluteString.contains("/move_messages"))
        }
    }

    func testSetFlagsChunksPerFlagLeg() async throws {
        // One flag over 1500 UIDs: two chunked calls, no partial → no throw.
        let http = RecordingHTTPTransport(responses: [
            (Data(submitted.utf8), 200),
            (Data(submitted.utf8), 200),
        ])
        let client = makeClient(http)
        let uids = Array(UInt32(1)...1500)
        try await client.setFlags(folder: "INBOX", uids: uids, flags: [.seen], operation: .add)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { requestIds($0).count }, [1000, 500])
    }

    // MARK: - Partial failure

    func testMovePartialFailureThrowsWithSplit() async throws {
        let body = #"{"status":"partial","moved_ids":[1,2],"failed_ids":[3]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = makeClient(http)
        do {
            try await client.move(folder: "INBOX", uids: [1, 2, 3], destination: "Archive")
            XCTFail("expected bulkPartialFailure")
        } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded, [1, 2])
            XCTAssertEqual(failed, [3])
        }
    }

    func testSetFlagsPartialFailureThrowsWithSplit() async throws {
        let body = #"{"status":"partial","flagged_ids":[1],"failed_ids":[2]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let client = makeClient(http)
        do {
            try await client.setFlags(folder: "INBOX", uids: [1, 2], flags: [.seen], operation: .add)
            XCTFail("expected bulkPartialFailure")
        } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded, [1])
            XCTAssertEqual(failed, [2])
        }
    }

    func testSetFlagsMultiFlagPartialFailureMerges() async throws {
        // Both flag legs report the same split (identical bodies keep the
        // concurrent request→response pairing deterministic); the merge
        // must union the failures and never count a failed UID as
        // succeeded.
        let body = #"{"status":"partial","flagged_ids":[1],"failed_ids":[2]}"#
        let http = RecordingHTTPTransport(responses: [
            (Data(body.utf8), 200),
            (Data(body.utf8), 200),
        ])
        let client = makeClient(http)
        do {
            try await client.setFlags(
                folder: "INBOX", uids: [1, 2], flags: [.seen, .flagged], operation: .add
            )
            XCTFail("expected bulkPartialFailure")
        } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded, [1])
            XCTAssertEqual(failed, [2])
        }
    }

    func testMidChunkHardFailureAggregatesIntoPartial() async throws {
        // First chunk lands, second 500s ({"status":"unable"}): the walk
        // continues past the throw and reports the dead chunk's UIDs as
        // failed rather than surfacing a bare server error.
        let http = RecordingHTTPTransport(responses: [
            (Data(submitted.utf8), 200),
            (Data(#"{"status":"unable"}"#.utf8), 500),
        ])
        let client = makeClient(http)
        let uids = Array(UInt32(1)...1500)
        do {
            try await client.move(folder: "INBOX", uids: uids, destination: "Archive")
            XCTFail("expected bulkPartialFailure")
        } catch CabalmailError.bulkPartialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded, Set(UInt32(1)...1000))
            XCTAssertEqual(failed, Set(UInt32(1001)...1500))
        }
    }

    func testTotalFailureRethrowsOriginalError() async throws {
        // Nothing succeeded → the caller gets the real server error, not a
        // partial-failure with an empty succeeded set.
        let http = RecordingHTTPTransport(responses: [
            (Data(#"{"status":"unable"}"#.utf8), 500),
        ])
        let client = makeClient(http)
        do {
            try await client.move(folder: "INBOX", uids: [1, 2], destination: "Archive")
            XCTFail("expected server error")
        } catch CabalmailError.bulkPartialFailure {
            XCTFail("total failure must not masquerade as partial")
        } catch let error as CabalmailError {
            guard case .server = error else {
                return XCTFail("expected .server, got \(error)")
            }
        }
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

    private func requestIds(_ request: URLRequest) -> [Int] {
        let json = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        return (json as? [String: Any])?["ids"] as? [Int] ?? []
    }
}
