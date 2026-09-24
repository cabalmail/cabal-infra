import XCTest
@testable import CabalmailKit

/// `/mark_folder_read` through the API-backed IMAP client (cross-media plan,
/// decision 6). Its own file because `ApiBackedImapClientTests` sits at
/// SwiftLint's `type_body_length` cap.
final class ApiBackedImapClientMarkFolderReadTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    func testMarkFolderReadIssuesPutAndReturnsFlipped() async throws {
        let body = #"{"status":"marked","flipped":17}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let flipped = try await client.markFolderRead(folder: "Projects/Alpha")
        XCTAssertEqual(flipped, 17)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/mark_folder_read"))
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["folder"] as? String, "Projects/Alpha")
        XCTAssertEqual(payload?["host"] as? String, "imap.example.com")
    }
}
