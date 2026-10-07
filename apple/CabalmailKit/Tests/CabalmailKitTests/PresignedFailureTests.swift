import XCTest
@testable import CabalmailKit

/// A presigned S3 request bypasses the API's `send`, so its failures are
/// mapped where it is made: `.http` with S3's reply, read as the status
/// (the XML isn't the API's JSON). The GET side is pinned in
/// `ApiBackedImapClientFetchBodyFailureTests`.
final class PresignedFailureTests: XCTestCase {
    func testAFailedPresignedUploadIsHttp() async throws {
        let refusal = "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>"
        let http = RecordingHTTPTransport(responses: [(Data(refusal.utf8), 403)])
        let api = URLSessionApiClient(
            configuration: TestFixtures.makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        do {
            let url = try XCTUnwrap(URL(string: "https://s3.example.com/put-here"))
            try await api.uploadAttachment(url: url, mimeType: "", data: Data())
            XCTFail("expected the upload to fail")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .http(status: 403, body: refusal))
            XCTAssertEqual(error.localizedDescription, "The server couldn't complete that request (403).")
        }
    }
}
