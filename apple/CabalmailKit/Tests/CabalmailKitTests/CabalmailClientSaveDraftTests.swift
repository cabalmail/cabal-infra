import XCTest
@testable import CabalmailKit

/// Covers `CabalmailClient.saveDraft(_:)` — the path the macOS compose
/// window uses to push the current buffer to the user's IMAP `Drafts`
/// folder via the `/send` Lambda's `draft=true` branch.
///
/// The Lambda side appends the message to Drafts with the `\Draft` flag
/// and skips SMTP entirely; this suite pins the client-side wire shape so
/// the Lambda gets exactly what it expects (and so a future refactor of
/// the submit() path can't silently flip the flag back to `false`).
final class CabalmailClientSaveDraftTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    private func makeClient(transport: RecordingHTTPTransport) throws -> CabalmailClient {
        let config = makeConfiguration()
        let auth = StubAuthService()
        let api = URLSessionApiClient(
            configuration: config,
            authService: auth,
            transport: transport
        )
        let imap = LiveImapClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let smtp = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: ScriptedByteStream()),
            authService: auth
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let envelopes = try EnvelopeCache(directory: tmp.appendingPathComponent("e"))
        let bodies = try MessageBodyCache(directory: tmp.appendingPathComponent("b"))
        let drafts = try DraftStore(directory: tmp.appendingPathComponent("d"))
        let outbox = try Outbox(directory: tmp.appendingPathComponent("o"))
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: api,
            imapClient: imap,
            smtpClient: smtp,
            addressCache: AddressCache(),
            envelopeCache: envelopes,
            bodyCache: bodies,
            draftStore: drafts,
            outbox: outbox
        )
    }

    private func sampleMessage() -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "cabalmail.example")],
            cc: [],
            bcc: [],
            subject: "wip draft",
            textBody: "still thinking",
            htmlBody: "<p>still thinking</p>"
        )
    }

    func testSaveDraftPostsToSendWithDraftFlagTrue() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"saved"}"#.utf8), 200)])
        let client = try makeClient(transport: http)

        try await client.saveDraft(sampleMessage())

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/send"))
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["draft"] as? Bool, true,
                       "saveDraft must set the draft flag so /send APPENDs to Drafts instead of submitting via SMTP")
        XCTAssertEqual(payload?["sender"] as? String, "alice@cabalmail.example")
        XCTAssertEqual(payload?["subject"] as? String, "wip draft")
    }

    func testSaveDraftSurfacesTransportErrors() async throws {
        // No canned responses: the recording transport throws .transport
        // for the only request, which saveDraft should propagate so the
        // compose UI can keep the window open with an error banner.
        let http = RecordingHTTPTransport(responses: [])
        let client = try makeClient(transport: http)

        do {
            try await client.saveDraft(sampleMessage())
            XCTFail("expected saveDraft to throw on a transport error")
        } catch is CabalmailError {
            // Expected — surface the error to the caller, do not queue.
        }
    }

    func testSendStillSetsDraftFalseSoExistingPathIsUnaffected() async throws {
        // Belt-and-suspenders: the existing send path must keep posting
        // draft=false so a regular Send still routes through SMTP rather
        // than silently landing in Drafts after the saveDraft work.
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        let client = try makeClient(transport: http)

        _ = try await client.send(sampleMessage())

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["draft"] as? Bool, false)
    }
}
