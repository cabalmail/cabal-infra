import XCTest
@testable import CabalmailKit

/// Pins the batching in `CabalmailClient.stageAttachments`.
///
/// `/upload_url` refuses more than 32 files in a single request. That bound
/// is about the shape of one request, not about how many attachments a
/// message may carry, so a bundle bigger than one batch has to stage across
/// several calls. Staging it in one call instead would turn the endpoint's
/// per-request limit into a per-message attachment cap — precisely what
/// removing the server-side count cap was meant to get rid of.
final class AttachmentStagingBatchTests: XCTestCase {
    private func makeClient(transport: RecordingHTTPTransport) -> URLSessionApiClient {
        let config = Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
        return URLSessionApiClient(
            configuration: config,
            authService: StubAuthService(),
            transport: transport
        )
    }

    private func message(attachmentCount: Int) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "x.example")],
            subject: "hello",
            textBody: "hi",
            attachments: (0..<attachmentCount).map { index in
                Attachment(
                    filename: "file-\(index).bin",
                    mimeType: "application/octet-stream",
                    data: Data([UInt8(index % 256)])
                )
            }
        )
    }

    /// Scripts one `/upload_url` reply per batch, each followed by a 200 for
    /// every S3 PUT that batch performs.
    private func responses(forBatches batches: [Int]) -> [(Data, Int)] {
        var scripted: [(Data, Int)] = []
        var minted = 0
        for size in batches {
            let entries = (0..<size).map { offset -> String in
                let slot = minted + offset
                return "{\"key\":\"outbound/u/\(slot)/file-\(slot).bin\","
                    + "\"url\":\"https://s3.example/put/\(slot)\"}"
            }
            let payload = "{\"uploads\":[\(entries.joined(separator: ","))]}"
            scripted.append((Data(payload.utf8), 200))
            scripted.append(contentsOf: Array(repeating: (Data(), 200), count: size))
            minted += size
        }
        return scripted
    }

    private func presignRequests(_ transport: RecordingHTTPTransport) async -> [URLRequest] {
        await transport.requests.filter { $0.url?.path.hasSuffix("/upload_url") == true }
    }

    private func batchSizes(of requests: [URLRequest]) throws -> [Int] {
        try requests.map { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return try XCTUnwrap(json?["files"] as? [[String: Any]]).count
        }
    }

    func testBundleLargerThanOneBatchStagesAcrossSeveralCalls() async throws {
        let transport = RecordingHTTPTransport(responses: responses(forBatches: [32, 8]))
        let staged = try await CabalmailClient.stageAttachments(
            message(attachmentCount: 40),
            api: makeClient(transport: transport),
            imapHost: "imap.cabalmail.example"
        )

        XCTAssertEqual(staged.count, 40)
        let presigns = await presignRequests(transport)
        XCTAssertEqual(presigns.count, 2, "40 attachments should presign in two batches")
        XCTAssertEqual(try batchSizes(of: presigns), [32, 8])
    }

    /// The seam between batches must not reorder the bundle: `/send` pairs
    /// filenames to S3 keys positionally, so a shuffle here would attach the
    /// right bytes under the wrong names.
    func testOrderSurvivesTheBatchSeam() async throws {
        let transport = RecordingHTTPTransport(responses: responses(forBatches: [32, 8]))
        let staged = try await CabalmailClient.stageAttachments(
            message(attachmentCount: 40),
            api: makeClient(transport: transport),
            imapHost: "imap.cabalmail.example"
        )

        XCTAssertEqual(staged.map(\.filename), (0..<40).map { "file-\($0).bin" })
        XCTAssertEqual(staged.map(\.s3Key), (0..<40).map { "outbound/u/\($0)/file-\($0).bin" })
    }

    func testExactlyOneBatchDoesNotSplit() async throws {
        let transport = RecordingHTTPTransport(responses: responses(forBatches: [32]))
        let staged = try await CabalmailClient.stageAttachments(
            message(attachmentCount: 32),
            api: makeClient(transport: transport),
            imapHost: "imap.cabalmail.example"
        )

        XCTAssertEqual(staged.count, 32)
        let presigns = await presignRequests(transport)
        XCTAssertEqual(presigns.count, 1, "a full but not overfull batch must not split")
    }

    func testEmptyBundleIssuesNoRequests() async throws {
        let transport = RecordingHTTPTransport(responses: [])
        let staged = try await CabalmailClient.stageAttachments(
            message(attachmentCount: 0),
            api: makeClient(transport: transport),
            imapHost: "imap.cabalmail.example"
        )

        XCTAssertTrue(staged.isEmpty)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "an attachment-free message must not presign")
    }
}
