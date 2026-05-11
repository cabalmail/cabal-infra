import XCTest
@testable import CabalmailKit

final class ApiBackedImapClientTests: XCTestCase {
    private func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    // MARK: - Envelope conversion

    func testMakeEnvelopeFlattensLambdaShape() {
        let raw = ApiEnvelope(
            id: 42,
            date: "2024-01-15 10:30:45+00:00",
            subject: "Hello",
            from: ["alice@example.com"],
            to: ["bob@example.com", "undisclosed-recipients"],
            cc: [],
            flags: ["\\Seen", "\\Flagged", "Junk"],
            structure: .list([.string("text"), .string("plain")]),
            priority: nil
        )
        let env = ApiBackedImapClient.makeEnvelope(raw)
        XCTAssertEqual(env.uid, 42)
        XCTAssertEqual(env.subject, "Hello")
        XCTAssertEqual(env.from.first?.mailbox, "alice")
        XCTAssertEqual(env.from.first?.host, "example.com")
        XCTAssertEqual(env.to.count, 2)
        XCTAssertEqual(env.to[1].mailbox, "undisclosed-recipients")
        XCTAssertTrue(env.flags.contains(.seen))
        XCTAssertTrue(env.flags.contains(.flagged))
        XCTAssertTrue(env.flags.contains(.keyword("Junk")))
    }

    func testParseLambdaDateHandlesPythonStrFormat() {
        let date = ApiBackedImapClient.parseLambdaDate("2024-01-15 10:30:45+00:00")
        XCTAssertNotNil(date)

        let nilString = ApiBackedImapClient.parseLambdaDate("None")
        XCTAssertNil(nilString)

        let empty = ApiBackedImapClient.parseLambdaDate("")
        XCTAssertNil(empty)

        let actuallyNil = ApiBackedImapClient.parseLambdaDate(nil)
        XCTAssertNil(actuallyNil)
    }

    func testParseAddressSplitsOnLastAt() {
        let addr = ApiBackedImapClient.parseAddress("alice@example.com")
        XCTAssertEqual(addr?.mailbox, "alice")
        XCTAssertEqual(addr?.host, "example.com")

        let weird = ApiBackedImapClient.parseAddress("a@b@example.com")
        XCTAssertEqual(weird?.mailbox, "a@b")
        XCTAssertEqual(weird?.host, "example.com")

        let placeholder = ApiBackedImapClient.parseAddress("undisclosed-recipients")
        XCTAssertEqual(placeholder?.mailbox, "undisclosed-recipients")
        XCTAssertEqual(placeholder?.host, "")
    }

    func testBodyStructureDetectsAttachment() {
        let withAttachment = BodyStructureNode.list([
            .list([.string("text"), .string("plain")]),
            .list([.string("application"), .string("pdf")]),
        ])
        XCTAssertTrue(withAttachment.hasAttachments)

        let plain = BodyStructureNode.list([
            .string("text"),
            .string("plain"),
        ])
        XCTAssertFalse(plain.hasAttachments)
    }

    // MARK: - Wire shape (URLs and bodies)

    func testListFoldersHitsExpectedURL() async throws {
        let body = #"{"folders":["INBOX","Sent"],"sub_folders":["INBOX"]}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let folders = try await client.listFolders()
        XCTAssertEqual(folders.map(\.path), ["INBOX", "Sent"])
        XCTAssertEqual(folders[0].isSubscribed, true)
        XCTAssertEqual(folders[1].isSubscribed, false)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let url = requests[0].url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/list_folders"))
        XCTAssertTrue(url.contains("host=imap.example.com"))
    }

    func testFolderStatusDecodesLambdaShape() async throws {
        let body = #"{"messages":42,"unseen":3,"uid_validity":12345,"uid_next":100}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let status = try await client.status(path: "INBOX")
        XCTAssertEqual(status.messages, 42)
        XCTAssertEqual(status.unseen, 3)
        XCTAssertEqual(status.uidValidity, 12345)
        XCTAssertEqual(status.uidNext, 100)
    }

    func testTopEnvelopesPagesByMessageIds() async throws {
        let listMessagesBody = #"{"message_ids":[10,9,8,7,6,5,4,3,2,1]}"#
        let listEnvelopesBody = """
        {
          "envelopes": {
            "10": {"id": 10, "date": "2024-01-15 10:30:45+00:00", "subject": "ten",
                    "from": ["a@x.com"], "to": [], "cc": [], "flags": [], "struct": null},
            "9":  {"id": 9, "date": "2024-01-14 09:00:00+00:00", "subject": "nine",
                    "from": ["b@x.com"], "to": [], "cc": [], "flags": ["\\\\Seen"], "struct": null}
          }
        }
        """
        let http = RecordingHTTPTransport(responses: [
            (Data(listMessagesBody.utf8), 200),
            (Data(listEnvelopesBody.utf8), 200),
        ])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let envelopes = try await client.topEnvelopes(folder: "INBOX", limit: 2, totalMessages: 10)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes[0].uid, 10)
        XCTAssertEqual(envelopes[1].uid, 9)
        XCTAssertTrue(envelopes[1].flags.contains(.seen))

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/list_messages"))
        XCTAssertTrue(requests[1].url!.absoluteString.contains("/list_envelopes"))
        XCTAssertTrue(requests[1].url!.absoluteString.contains("ids=%5B10,9%5D"))
    }

    func testTopEnvelopesShortCircuitsWhenEmpty() async throws {
        let http = RecordingHTTPTransport(responses: [])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let envelopes = try await client.topEnvelopes(folder: "INBOX", limit: 50, totalMessages: 0)
        XCTAssertTrue(envelopes.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 0, "empty mailbox should not hit the wire")
    }

    func testSetFlagsSendsOneRequestPerFlag() async throws {
        let body = #"{"message_ids":[]}"#
        let http = RecordingHTTPTransport(responses: [
            (Data(body.utf8), 200),
            (Data(body.utf8), 200),
        ])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        try await client.setFlags(
            folder: "INBOX",
            uids: [1, 2],
            flags: [.seen, .flagged],
            operation: .add
        )
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(request.url!.absoluteString.contains("/set_flag"))
        }
    }

    func testMoveMessagesIssuesPutWithExpectedBody() async throws {
        let body = #"{"status":"submitted"}"#
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        try await client.move(folder: "INBOX", uids: [1, 2, 3], destination: "Archive")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/move_messages"))
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["source"] as? String, "INBOX")
        XCTAssertEqual(payload?["destination"] as? String, "Archive")
    }

    func testSearchHitsLambdaAndReturnsUids() async throws {
        let http = RecordingHTTPTransport(
            responses: [(Data(#"{"message_ids":[7,11,42]}"#.utf8), 200)]
        )
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let result = try await client.search(folder: "INBOX", query: "TEXT \"hi\"")
        XCTAssertEqual(result, [7, 11, 42])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "GET")
        let url = request.url!.absoluteString
        XCTAssertTrue(url.contains("/search"))
        XCTAssertTrue(url.contains("host=imap.example.com"))
        XCTAssertTrue(url.contains("folder=INBOX"))
        // The query string round-trips as percent-encoded form.
        XCTAssertTrue(url.contains("query=TEXT"))
    }

    func testSendMessageHitsLambdaWithExpectedShape() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await api.sendMessage(SendMessageRequest(
            host: "imap.example.com",
            smtpHost: "smtp-out.example.com",
            sender: "alice@example.com",
            toList: ["bob@example.com"],
            ccList: [],
            bccList: [],
            subject: "hi",
            otherHeaders: ApiSendOtherHeaders(messageId: ["<abc@example.com>"]),
            htmlBody: "<p>Hi</p>",
            textBody: "Hi",
            draft: false
        ))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/send"))
        let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(payload?["sender"] as? String, "alice@example.com")
        XCTAssertEqual(payload?["smtp_host"] as? String, "smtp-out.example.com")
        let headers = payload?["other_headers"] as? [String: Any]
        XCTAssertEqual(headers?["message_id"] as? [String], ["<abc@example.com>"])
        // Default initializer omits attachments — the wire shape carries an
        // empty list so the Lambda doesn't need to special-case `null`.
        XCTAssertEqual((payload?["attachments"] as? [[String: Any]])?.count, 0)
    }

    func testSendMessageForwardsAttachmentS3Keys() async throws {
        let http = RecordingHTTPTransport(responses: [(Data(#"{"status":"submitted"}"#.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: makeConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        try await api.sendMessage(SendMessageRequest(
            host: "imap.example.com",
            smtpHost: "smtp-out.example.com",
            sender: "alice@example.com",
            toList: ["bob@example.com"],
            ccList: [],
            bccList: [],
            subject: "with attachment",
            otherHeaders: ApiSendOtherHeaders(messageId: ["<abc@example.com>"]),
            htmlBody: "",
            textBody: "see attached",
            draft: false,
            attachments: [
                ApiSendAttachment(
                    filename: "note.txt",
                    mimeType: "text/plain",
                    s3Key: "outbound/alice/uuid/note.txt"
                ),
            ]
        ))
        let requests = await http.requests
        let request = requests[0]
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let attachments = json?["attachments"] as? [[String: Any]]
        XCTAssertEqual(attachments?.count, 1)
        XCTAssertEqual(attachments?[0]["filename"] as? String, "note.txt")
        XCTAssertEqual(attachments?[0]["mime_type"] as? String, "text/plain")
        XCTAssertEqual(attachments?[0]["s3_key"] as? String, "outbound/alice/uuid/note.txt")
        XCTAssertNil(attachments?[0]["data"])
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
