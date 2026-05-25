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

}

// MARK: - searchEnvelopes
//
// `searchEnvelopes(_:)` tests live in their own extension so the primary
// XCTestCase body stays under SwiftLint's 250-line cap. XCTest still
// discovers the methods via the runtime, so no further wiring is needed.
extension ApiBackedImapClientTests {
    func testSearchEnvelopesSingleFolderRoundTrip() async throws {
        let body = """
        {
          "envelopes": [
            {"id": 42, "date": "2024-03-01 09:00:00+00:00", "subject": "hello",
             "from": ["a@x.com"], "to": ["b@y.com"], "cc": [], "flags": [],
             "struct": null, "folder": "INBOX"},
            {"id": 17, "date": "2024-02-12 18:30:00+00:00", "subject": "older",
             "from": ["c@x.com"], "to": [], "cc": [], "flags": ["\\\\Seen"],
             "struct": null, "folder": "INBOX"}
          ],
          "total_estimate": 2,
          "next_cursor": null,
          "folders_searched": ["INBOX"],
          "truncated": false
        }
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: searchTestConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let result = try await client.searchEnvelopes(
            SearchQuery(folder: "INBOX", text: "hello")
        )
        XCTAssertEqual(result.envelopes.count, 2)
        XCTAssertEqual(result.envelopes[0].envelope.uid, 42)
        XCTAssertEqual(result.envelopes[0].folder, "INBOX")
        XCTAssertEqual(result.envelopes[1].envelope.uid, 17)
        XCTAssertTrue(result.envelopes[1].envelope.flags.contains(.seen))
        XCTAssertEqual(result.totalEstimate, 2)
        XCTAssertNil(result.nextCursor)
        XCTAssertEqual(result.foldersSearched, ["INBOX"])
        XCTAssertFalse(result.truncated)

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let url = requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("/search_envelopes"))
        XCTAssertTrue(url.contains("host=imap.example.com"))
        XCTAssertTrue(url.contains("folder=INBOX"))
        XCTAssertTrue(url.contains("text=hello"))
    }

    func testSearchEnvelopesCrossFolderOmitsFolderParam() async throws {
        let body = """
        {
          "envelopes": [
            {"id": 5, "date": "2024-04-02 11:00:00+00:00", "subject": "x",
             "from": ["a@x.com"], "to": [], "cc": [], "flags": [],
             "struct": null, "folder": "Archive/2024"}
          ],
          "total_estimate": 1,
          "next_cursor": "abc",
          "folders_searched": ["INBOX", "Archive/2024"],
          "truncated": false
        }
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: searchTestConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        let result = try await client.searchEnvelopes(
            SearchQuery(text: "invoice", unread: true, limit: 25)
        )
        XCTAssertEqual(result.envelopes.first?.folder, "Archive/2024")
        XCTAssertEqual(result.nextCursor, "abc")

        let requests = await http.requests
        let url = requests[0].url!.absoluteString
        XCTAssertFalse(url.contains("folder="), "cross-folder mode must omit folder param: \(url)")
        XCTAssertTrue(url.contains("text=invoice"))
        XCTAssertTrue(url.contains("unread=1"))
        XCTAssertTrue(url.contains("limit=25"))
    }

    func testSearchEnvelopesEncodesStructuredFilters() async throws {
        let body = """
        {"envelopes": [], "total_estimate": 0, "next_cursor": null,
         "folders_searched": [], "truncated": false}
        """
        let http = RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: searchTestConfiguration(),
            authService: StubAuthService(),
            transport: http
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let since = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let before = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        _ = try await client.searchEnvelopes(SearchQuery(
            folder: "INBOX",
            text: "report",
            from: "alice@example.com",
            to: "bob@example.com",
            subject: "Q1",
            since: since,
            before: before,
            unread: false,
            flagged: true,
            hasAttachment: true,
            limit: 50,
            cursor: "cur42"
        ))
        let requests = await http.requests
        let url = requests[0].url!.absoluteString
        // URLComponents does not percent-encode `@` in query values (it's
        // valid per RFC 3986 sub-delims-in-query) — compare against the
        // raw form rather than the percent-encoded one.
        XCTAssertTrue(url.contains("from=alice@example.com"))
        XCTAssertTrue(url.contains("to=bob@example.com"))
        XCTAssertTrue(url.contains("subject=Q1"))
        XCTAssertTrue(url.contains("since=2026-01-01"))
        XCTAssertTrue(url.contains("before=2026-04-01"))
        XCTAssertFalse(url.contains("unread="), "false flag should be omitted")
        XCTAssertTrue(url.contains("flagged=1"))
        XCTAssertTrue(url.contains("has_attachment=1"))
        XCTAssertTrue(url.contains("limit=50"))
        XCTAssertTrue(url.contains("cursor=cur42"))
    }

    private func searchTestConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }
}
