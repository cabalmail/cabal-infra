import XCTest
@testable import CabalmailKit

/// Covers `CabalmailClient.saveDraft(_:replacing:)` and the send-from-draft
/// cleanup — the draft-lifecycle surface the compose window uses to keep
/// exactly one server copy per draft (`/save_draft` save / replace /
/// discard, plus `/send`'s `discard_draft_uid`).
///
/// These pin the client-side wire shape so the Lambdas get exactly what
/// they expect, and so a refactor of the submit path can't silently drop
/// the replace chain.
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

    private let savedResponse = Data(
        #"{"status":"saved","uid":7,"uidvalidity":99,"replaced":false}"#.utf8
    )

    func testSaveDraftPostsToSaveDraftAndReturnsServerRef() async throws {
        let http = RecordingHTTPTransport(responses: [(savedResponse, 200)])
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(sampleMessage())

        XCTAssertEqual(ref, DraftServerRef(uid: 7, uidValidity: 99))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/save_draft"))
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["sender"] as? String, "alice@cabalmail.example")
        XCTAssertEqual(payload?["subject"] as? String, "wip draft")
        XCTAssertNil(payload?["replaces_uid"],
                     "a first save must not name a copy to replace")
    }

    func testSaveDraftPassesReplaceCoordinates() async throws {
        let http = RecordingHTTPTransport(responses: [(savedResponse, 200)])
        let client = try makeClient(transport: http)

        _ = try await client.saveDraft(
            sampleMessage(),
            replacing: DraftServerRef(uid: 3, uidValidity: 99)
        )

        let requests = await http.requests
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["replaces_uid"] as? Int, 3)
        XCTAssertEqual(payload?["replaces_uidvalidity"] as? Int, 99)
    }

    func testSaveDraftWithoutAppenduidReturnsNilRef() async throws {
        // A server that can't report UIDPLUS coordinates still saved the
        // draft; the caller just can't run the replace chain.
        let degraded = Data(#"{"status":"saved","uid":null,"uidvalidity":null,"replaced":false}"#.utf8)
        let http = RecordingHTTPTransport(responses: [(degraded, 200)])
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(sampleMessage())

        XCTAssertNil(ref)
    }

    func testSaveDraftSurfacesTransportErrors() async throws {
        // No canned responses: the recording transport throws .transport
        // for the only request, which saveDraft should propagate so the
        // compose UI can keep the window open with an error banner.
        let http = RecordingHTTPTransport(responses: [])
        let client = try makeClient(transport: http)

        do {
            _ = try await client.saveDraft(sampleMessage())
            XCTFail("expected saveDraft to throw on a transport error")
        } catch is CabalmailError {
            // Expected — surface the error to the caller, do not queue.
        }
    }

    func testDiscardDraftPostsDiscardOp() async throws {
        let http = RecordingHTTPTransport(
            responses: [(Data(#"{"status":"discarded","discarded":true}"#.utf8), 200)]
        )
        let client = try makeClient(transport: http)

        let discarded = try await client.discardDraft(DraftServerRef(uid: 4, uidValidity: 99))

        XCTAssertTrue(discarded)
        let requests = await http.requests
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/save_draft"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["op"] as? String, "discard")
        XCTAssertEqual(payload?["replaces_uid"] as? Int, 4)
        XCTAssertEqual(payload?["replaces_uidvalidity"] as? Int, 99)
    }

    func testSendIncludesDiscardDraftCoordinates() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        let client = try makeClient(transport: http)

        _ = try await client.send(
            sampleMessage(),
            discardingDraft: DraftServerRef(uid: 11, uidValidity: 42)
        )

        let requests = await http.requests
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/send"))
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["discard_draft_uid"] as? Int, 11)
        XCTAssertEqual(payload?["discard_draft_uidvalidity"] as? Int, 42)
    }

    func testSendWithoutDraftRefOmitsDiscardKeys() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        let client = try makeClient(transport: http)

        _ = try await client.send(sampleMessage())

        let requests = await http.requests
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertNil(payload?["discard_draft_uid"])
        XCTAssertEqual(payload?["draft"] as? Bool, false,
                       "a regular Send must keep posting draft=false")
    }

    func testWireHeadersWrapBareMessageIds() {
        // ReplyBuilder and persisted Drafts carry bare ids; RFC 5322 (and
        // the React client) put angle brackets on the wire. The submit
        // seam is where every sender path normalizes.
        let message = OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [],
            subject: "s",
            inReplyTo: "parent@x.example",
            references: ["a@x.example", "<b@y.example>", ""],
            messageId: "<m@z.example>"
        )
        let headers = CabalmailClient.wireHeaders(for: message)
        XCTAssertEqual(headers.messageId, ["<m@z.example>"])
        XCTAssertEqual(headers.inReplyTo, ["<parent@x.example>"])
        XCTAssertEqual(headers.references, ["<a@x.example>", "<b@y.example>"])
    }
}
