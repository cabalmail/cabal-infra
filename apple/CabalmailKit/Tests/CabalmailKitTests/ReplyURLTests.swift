import XCTest
@testable import CabalmailKit

/// URLs taken from API replies are followed only when they are absolute
/// http(s) with a host (#1804). `sign_url` answers the literal `"Error"`
/// inside a 200 when it can't sign, which `URL(string:)` accepts as a
/// relative URL; each endpoint that hands back a URL now reads that as no
/// URL, with the copy it already had for one. The presigned body URL is
/// pinned in `ApiBackedImapClientFetchBodyTests` and BIMI in
/// `BimiUrlCacheTests`.
final class ReplyURLTests: XCTestCase {
    private static let unfollowable = ["Error", "", "/relative/path", "https:///no-host", "ftp://s3.example/f", "s3.example/f"]

    func testOnlyAbsoluteHTTPURLsWithAHostAreFollowable() {
        for raw in Self.unfollowable {
            XCTAssertNil(URL(followableReplyString: raw), raw)
        }
        for raw in ["https://bucket.s3.amazonaws.com/a?X-Amz-Signature=1", "http://localhost:9000/a", "HTTPS://S3.EXAMPLE/A"] {
            XCTAssertEqual(URL(followableReplyString: raw)?.absoluteString, raw, raw)
        }
    }

    func testAnAttachmentURLThatIsNotFollowableReadsAsInvalid() async {
        for raw in Self.unfollowable {
            let error = await Self.error(replying: #"{"url": "\#(raw)"}"#) {
                _ = try await $0.fetchAttachmentURL(FetchAttachmentRequest(
                    host: "h", folder: "INBOX", id: 1, index: 0, filename: "a.pdf", markSeen: false
                ))
            }
            XCTAssertEqual(error as? CabalmailError, .decoding("fetch_attachment returned invalid url"), raw)
        }
    }

    func testAnInlineImageURLThatIsNotFollowableReadsAsInvalid() async {
        for raw in Self.unfollowable {
            let error = await Self.error(replying: #"{"url": "\#(raw)"}"#) {
                _ = try await $0.fetchInlineImageURL(host: "h", folder: "INBOX", id: 1, contentId: "c", markSeen: false)
            }
            XCTAssertEqual(error as? CabalmailError, .decoding("fetch_inline_image returned invalid url"), raw)
        }
    }

    func testAnUploadURLThatIsNotFollowableReadsAsInvalid() async {
        for raw in Self.unfollowable {
            let error = await Self.error(replying: #"{"uploads": [{"key": "k", "url": "\#(raw)"}]}"#) {
                _ = try await $0.requestAttachmentUploads(
                    host: "h", files: [AttachmentUploadSlot(filename: "a.txt", mimeType: "text/plain")]
                )
            }
            XCTAssertEqual(error as? CabalmailError, .decoding("upload_url returned an invalid URL"), raw)
        }
    }

    /// The control: a real presigned URL from each endpoint is handed back.
    func testAFollowableURLIsHandedBack() async throws {
        let signed = "https://bucket.s3.amazonaws.com/a?X-Amz-Signature=1"
        let attachment = try await Self.client(replying: #"{"url": "\#(signed)"}"#).fetchAttachmentURL(
            FetchAttachmentRequest(host: "h", folder: "INBOX", id: 1, index: 0, filename: "a.pdf", markSeen: false)
        )
        XCTAssertEqual(attachment.absoluteString, signed)
        let slot = AttachmentUploadSlot(filename: "a.txt", mimeType: "text/plain")
        let uploads = try await Self.client(replying: #"{"uploads": [{"key": "k", "url": "\#(signed)"}]}"#)
            .requestAttachmentUploads(host: "h", files: [slot])
        XCTAssertEqual(uploads.map(\.url.absoluteString), [signed])
    }

    private static func error(
        replying body: String,
        _ call: (URLSessionApiClient) async throws -> Void
    ) async -> Error? {
        do {
            try await call(client(replying: body))
            return nil
        } catch {
            return error
        }
    }

    private static func client(replying body: String) -> URLSessionApiClient {
        URLSessionApiClient(
            configuration: TestFixtures.makeConfiguration(),
            authService: StubAuthService(),
            transport: ScriptedHTTPTransport { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: nil)!
                return (Data(body.utf8), response)
            }
        )
    }
}
