import XCTest
@testable import CabalmailKit

/// Pins the compose payload `/send` and `/save_draft` share (`ComposeWireBody`)
/// and, just as importantly, the parts they do not: `smtp_host` and `draft`
/// belong to `/send` alone, and each endpoint's UID pair is its own.
final class ComposeWireBodyTests: XCTestCase {
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

    private let headers = ApiSendOtherHeaders(
        messageId: ["<m@z.example>"],
        inReplyTo: ["<parent@x.example>"],
        references: ["<a@x.example>", "<b@y.example>"]
    )

    private let attachments = [
        ApiSendAttachment(filename: "a.pdf", mimeType: "application/pdf", s3Key: "u/1/a.pdf"),
        ApiSendAttachment(filename: "b.png", mimeType: "image/png", s3Key: "u/1/b.png"),
    ]

    private func sendRequest(
        discardUid: UInt32? = nil,
        discardValidity: UInt32? = nil
    ) -> SendMessageRequest {
        SendMessageRequest(
            host: "imap.cabalmail.example",
            smtpHost: "smtp.cabalmail.example",
            sender: "alice@cabalmail.example",
            toList: ["bob@x.example"],
            ccList: ["carol@y.example"],
            bccList: ["dave@z.example"],
            subject: "hello",
            otherHeaders: headers,
            htmlBody: "<p>hi</p>",
            textBody: "hi",
            draft: false,
            attachments: attachments,
            discardDraftUid: discardUid,
            discardDraftUidValidity: discardValidity
        )
    }

    private func draftRequest(
        replacesUid: UInt32? = nil,
        replacesValidity: UInt32? = nil
    ) -> SaveDraftRequest {
        SaveDraftRequest(
            host: "imap.cabalmail.example",
            sender: "alice@cabalmail.example",
            toList: ["bob@x.example"],
            ccList: ["carol@y.example"],
            bccList: ["dave@z.example"],
            subject: "hello",
            otherHeaders: headers,
            htmlBody: "<p>hi</p>",
            textBody: "hi",
            attachments: attachments,
            replacesUid: replacesUid,
            replacesUidValidity: replacesValidity
        )
    }

    private func body(of transport: RecordingHTTPTransport) async throws -> [String: Any] {
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let data = try XCTUnwrap(requests.first?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertSharedComposeKeys(_ payload: [String: Any]) throws {
        XCTAssertEqual(payload["host"] as? String, "imap.cabalmail.example")
        XCTAssertEqual(payload["sender"] as? String, "alice@cabalmail.example")
        XCTAssertEqual(payload["to_list"] as? [String], ["bob@x.example"])
        XCTAssertEqual(payload["cc_list"] as? [String], ["carol@y.example"])
        XCTAssertEqual(payload["bcc_list"] as? [String], ["dave@z.example"])
        XCTAssertEqual(payload["subject"] as? String, "hello")
        XCTAssertEqual(payload["html"] as? String, "<p>hi</p>")
        XCTAssertEqual(payload["text"] as? String, "hi")

        let wireHeaders = try XCTUnwrap(payload["other_headers"] as? [String: Any])
        XCTAssertEqual(Set(wireHeaders.keys), ["message_id", "in_reply_to", "references"])
        XCTAssertEqual(wireHeaders["message_id"] as? [String], ["<m@z.example>"])
        XCTAssertEqual(wireHeaders["in_reply_to"] as? [String], ["<parent@x.example>"])
        XCTAssertEqual(wireHeaders["references"] as? [String],
                       ["<a@x.example>", "<b@y.example>"])

        let wireAttachments = try XCTUnwrap(payload["attachments"] as? [[String: Any]])
        XCTAssertEqual(wireAttachments.count, 2)
        // Order matters: the Lambda's `index` for an inline part is this
        // list's position.
        XCTAssertEqual(wireAttachments[0]["filename"] as? String, "a.pdf")
        XCTAssertEqual(wireAttachments[0]["mime_type"] as? String, "application/pdf")
        XCTAssertEqual(wireAttachments[0]["s3_key"] as? String, "u/1/a.pdf")
        XCTAssertEqual(wireAttachments[1]["filename"] as? String, "b.png")
        XCTAssertEqual(Set(wireAttachments[1].keys), ["filename", "mime_type", "s3_key"])
    }

    func testSendCarriesTheSharedComposeKeysPlusItsOwn() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        try await makeClient(transport: http).sendMessage(sendRequest())

        let payload = try await body(of: http)
        try assertSharedComposeKeys(payload)
        XCTAssertEqual(payload["smtp_host"] as? String, "smtp.cabalmail.example")
        XCTAssertEqual(payload["draft"] as? Bool, false)
        XCTAssertEqual(
            Set(payload.keys),
            ["host", "smtp_host", "sender", "to_list", "cc_list", "bcc_list", "subject",
             "other_headers", "html", "text", "draft", "attachments"],
            "/send posts the shared compose keys plus smtp_host and draft, nothing else"
        )
    }

    func testSaveDraftCarriesTheSameComposeKeysWithoutTheSmtpOnes() async throws {
        let saved = Data(#"{"status":"saved","uid":7,"uidvalidity":99,"replaced":false}"#.utf8)
        let http = RecordingHTTPTransport(responses: [(saved, 200)])
        _ = try await makeClient(transport: http).saveDraft(draftRequest())

        let payload = try await body(of: http)
        try assertSharedComposeKeys(payload)
        XCTAssertEqual(
            Set(payload.keys),
            ["host", "sender", "to_list", "cc_list", "bcc_list", "subject",
             "other_headers", "html", "text", "attachments"],
            "/save_draft is the /send shape minus the SMTP concerns"
        )
    }

    func testSendDiscardPairIsAllOrNothing() async throws {
        for (uid, validity) in [(UInt32(11), nil as UInt32?), (nil, 42)] {
            let http = RecordingHTTPTransport(
                responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)]
            )
            try await makeClient(transport: http).sendMessage(
                sendRequest(discardUid: uid, discardValidity: validity)
            )

            let payload = try await body(of: http)
            XCTAssertNil(payload["discard_draft_uid"],
                         "half a UID pair cannot name a copy to expunge")
            XCTAssertNil(payload["discard_draft_uidvalidity"])
        }
    }

    func testSaveDraftReplacePairIsAllOrNothing() async throws {
        let saved = Data(#"{"status":"saved","uid":7,"uidvalidity":99,"replaced":false}"#.utf8)
        for (uid, validity) in [(UInt32(3), nil as UInt32?), (nil, 99)] {
            let http = RecordingHTTPTransport(responses: [(saved, 200)])
            _ = try await makeClient(transport: http).saveDraft(
                draftRequest(replacesUid: uid, replacesValidity: validity)
            )

            let payload = try await body(of: http)
            XCTAssertNil(payload["replaces_uid"],
                         "half a UID pair cannot name a copy to supersede")
            XCTAssertNil(payload["replaces_uidvalidity"])
        }
    }
}
