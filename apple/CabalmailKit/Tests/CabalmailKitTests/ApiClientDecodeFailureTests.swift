import XCTest
@testable import CabalmailKit

/// No endpoint lets `Swift.DecodingError` out of the package (#1805).
///
/// `CabalmailError` promises that lower-level failures are normalized into
/// it, but the client used to decode most replies with a bare `JSONDecoder`,
/// so an HTML error page, an empty body or a drifted shape behind a 200
/// escaped as `DecodingError` and the UI printed Foundation's "The data
/// couldn't be read because it isn't in the correct format." Every endpoint
/// that reads its reply is driven here with 200s it can't use: a strict one
/// throws `.decoding` naming the endpoint, and a lenient one (a `try?` with
/// a default, kept on purpose) still answers its default.
final class ApiClientDecodeFailureTests: XCTestCase {
    /// Not JSON at all, so no reply type can decode them.
    private static let notJSON = ["<html><body>502 Bad Gateway</body></html>", ""]
    /// JSON of the wrong shape. Some reply types have only optional fields
    /// and accept an unexpected object, so these assert only that whatever
    /// comes out is a `CabalmailError`.
    private static let wrongShape = ["[]", #"{"unexpected": true}"#, "42", "null"]

    func testAStrictEndpointsUnparseable200IsDecodingNamingTheEndpoint() async {
        for endpoint in Self.endpoints {
            guard case .strict(let name) = endpoint.reading else { continue }
            for body in Self.notJSON {
                let error = await Self.error(calling: endpoint, replying: body)
                let label = "\(endpoint.label) <- \(body.debugDescription)"
                XCTAssertEqual(error as? CabalmailError, .decoding("\(name) returned an unexpected reply"), label)
                XCTAssertEqual(
                    error?.localizedDescription,
                    "Couldn't read the server's reply. \(name) returned an unexpected reply.",
                    label
                )
            }
        }
    }

    func testALenientEndpointStillReadsAnUnparseable200AsItsDefault() async {
        for endpoint in Self.endpoints where endpoint.reading == .lenient {
            for body in Self.notJSON {
                let error = await Self.error(calling: endpoint, replying: body)
                XCTAssertNil(error, "\(endpoint.label) <- \(body.debugDescription)")
            }
        }
    }

    func testNoEndpointLetsADecodingErrorOutWhateverTheBody() async {
        for endpoint in Self.endpoints {
            for body in Self.notJSON + Self.wrongShape {
                let label = "\(endpoint.label) <- \(body.debugDescription)"
                guard let error = await Self.error(calling: endpoint, replying: body) else { continue }
                XCTAssertFalse(error is DecodingError, "\(label): \(error)")
                XCTAssertNotNil(error as? CabalmailError, "\(label): \(error)")
            }
        }
    }

    /// The log line says where the decode stopped and never what the reply
    /// held, because replies carry message content.
    func testTheLogNamesTheCodingPathAndNeverTheBody() async {
        let key = "key-\(UUID().uuidString)"
        let secret = "secret-\(UUID().uuidString)"
        let endpoint = Endpoint("listEnvelopes", .strict("list_envelopes")) {
            _ = try await $0.listEnvelopes(host: "h", folder: "INBOX", ids: [1])
        }
        let wrongType = #"{"envelopes": {"\#(key)": "\#(secret)"}}"#
        let error = await Self.error(calling: endpoint, replying: wrongType)
        XCTAssertEqual(error as? CabalmailError, .decoding("list_envelopes returned an unexpected reply"))
        _ = await Self.error(calling: endpoint, replying: "<html>\(secret)</html>")

        let lines = DebugLogStore.shared.snapshot().filter { $0.category == "API" }.map(\.message)
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("list_envelopes reply didn't decode") && $0.hasSuffix("envelopes.\(key)") },
            "no line names the coding path: \(lines.suffix(5))"
        )
        XCTAssertFalse(lines.contains { $0.contains(secret) }, "the reply's content reached the log")
    }

    /// The table above covers today's endpoints; this keeps a new one from
    /// bringing the bare decode back. The only strict `JSONDecoder` decode in
    /// `API/` is the one inside `decodeReply`. A `try?` is a deliberate
    /// lenient read and is not counted.
    func testTheOnlyStrictDecodeInTheClientIsDecodeReplys() throws {
        let api = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CabalmailKit
            .appendingPathComponent("Sources/CabalmailKit/API")
        var strict: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: api.path) where file.hasSuffix(".swift") {
            let lines = try String(contentsOf: api.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("try JSONDecoder()") {
                strict.append("\(file):\(index + 1)")
            }
        }
        XCTAssertEqual(strict.count, 1, "decode API replies through decodeReply: \(strict)")
        let helper = try String(contentsOf: api.appendingPathComponent("URLSessionApiClient.swift"), encoding: .utf8)
        XCTAssertTrue(
            helper.contains("func decodeReply") && helper.contains("return try JSONDecoder().decode(type, from: data)"),
            "decodeReply moved or changed shape, so the count above no longer means anything"
        )
    }

    // MARK: - Endpoints

    private enum Reading: Equatable {
        /// Decodes through `decodeReply`; the associated value is the path
        /// component the error names.
        case strict(String)
        /// Falls back to a default on a reply it can't parse.
        case lenient
    }

    private struct Endpoint: Sendable {
        let label: String
        let reading: Reading
        let call: @Sendable (URLSessionApiClient) async throws -> Void

        init(
            _ label: String,
            _ reading: Reading,
            _ call: @escaping @Sendable (URLSessionApiClient) async throws -> Void
        ) {
            self.label = label
            self.reading = reading
            self.call = call
        }
    }

    /// Every endpoint that reads its reply body. The rest (sends, deletes,
    /// subscribes) discard the body, so a 200 of any shape is success.
    private static let endpoints = mailEndpoints + accountEndpoints + rssEndpoints

    private static let mailEndpoints: [Endpoint] = [
        Endpoint("listFolders", .strict("list_folders")) { _ = try await $0.listFolders(host: "h") },
        Endpoint("folderStatus", .strict("folder_status")) {
            _ = try await $0.folderStatus(host: "h", folder: "INBOX", flagged: true)
        },
        Endpoint("listMessageIds", .strict("list_messages")) {
            _ = try await $0.listMessageIds(host: "h", folder: "INBOX", sortOrder: "REVERSE", sortField: "DATE",
                                            page: nil)
        },
        Endpoint("listEnvelopes", .strict("list_envelopes")) {
            _ = try await $0.listEnvelopes(host: "h", folder: "INBOX", ids: [1])
        },
        Endpoint("searchEnvelopes", .strict("search_envelopes")) {
            _ = try await $0.searchEnvelopes(host: "h", query: SearchQuery(text: "x"))
        },
        Endpoint("fetchMessage", .strict("fetch_message")) {
            _ = try await $0.fetchMessage(host: "h", folder: "INBOX", id: 1, markSeen: false)
        },
        Endpoint("listAttachments", .strict("list_attachments")) {
            _ = try await $0.listAttachments(host: "h", folder: "INBOX", id: 1, markSeen: false)
        },
        Endpoint("fetchAttachmentURL", .strict("fetch_attachment")) {
            _ = try await $0.fetchAttachmentURL(FetchAttachmentRequest(
                host: "h", folder: "INBOX", id: 1, index: 0, filename: "a.pdf", markSeen: false
            ))
        },
        Endpoint("fetchInlineImageURL", .strict("fetch_inline_image")) {
            _ = try await $0.fetchInlineImageURL(host: "h", folder: "INBOX", id: 1, contentId: "c", markSeen: false)
        },
        Endpoint("markFolderRead", .strict("mark_folder_read")) {
            _ = try await $0.markFolderRead(host: "h", folder: "INBOX")
        },
        Endpoint("setFlag", .lenient) {
            _ = try await $0.setFlag(SetFlagRequest(
                host: "h", folder: "INBOX", ids: [1], flag: "\\Seen", operation: "set",
                sortOrder: "REVERSE", sortField: "DATE"
            ))
        },
        Endpoint("moveMessages", .lenient) {
            _ = try await $0.moveMessages(MoveMessagesRequest(
                host: "h", source: "INBOX", destination: "Archive", ids: [1], sortOrder: "REVERSE", sortField: "DATE"
            ))
        },
        Endpoint("saveDraft", .strict("save_draft")) {
            _ = try await $0.saveDraft(SaveDraftRequest(
                host: "h", sender: "a@b.example", toList: [], ccList: [], bccList: [], subject: "s",
                otherHeaders: ApiSendOtherHeaders(), htmlBody: "", textBody: ""
            ))
        },
        Endpoint("discardDraft", .lenient) { _ = try await $0.discardDraft(host: "h", uid: 1, uidValidity: 1) },
        Endpoint("requestAttachmentUploads", .strict("upload_url")) {
            _ = try await $0.requestAttachmentUploads(
                host: "h", files: [AttachmentUploadSlot(filename: "a.txt", mimeType: "text/plain")]
            )
        },
    ]

    private static let accountEndpoints: [Endpoint] = [
        Endpoint("listAddresses", .strict("list")) { _ = try await $0.listAddresses() },
        Endpoint("listMyDomains", .lenient) { _ = try await $0.listMyDomains() },
        Endpoint("fetchBimiURL", .lenient) { _ = try await $0.fetchBimiURL(senderDomain: "example.com") },
        Endpoint("fetchDisplayName", .lenient) { _ = try await $0.fetchDisplayName() },
        Endpoint("fetchAppPreferences", .lenient) { _ = try await $0.fetchAppPreferences() },
        Endpoint("loadNavState", .lenient) { _ = try await $0.loadNavState() },
        Endpoint("listRules", .strict("get_rules")) { _ = try await $0.listRules() },
        Endpoint("setRules", .strict("set_rules")) { _ = try await $0.setRules([], expectedVersion: 1) },
        Endpoint("fetchPushEnvelope", .strict("push_envelope")) {
            _ = try await $0.fetchPushEnvelope(folder: "INBOX", uid: 1, messageID: nil)
        },
    ]

    private static let rssEndpoints: [Endpoint] = [
        Endpoint("listSubscriptions", .strict("rss_list_subscriptions")) { _ = try await $0.listSubscriptions() },
        Endpoint("subscribe", .strict("rss_subscribe")) {
            _ = try await $0.subscribe(url: "https://x.example/feed", folderId: nil)
        },
        Endpoint("unsubscribe", .strict("rss_unsubscribe")) { _ = try await $0.unsubscribe(subscriptionId: "s") },
        Endpoint("updateSubscription", .strict("rss_update_subscription")) {
            _ = try await $0.updateSubscription("s", RssSubscriptionUpdate(customTitle: "t"))
        },
        Endpoint("newFolder", .strict("rss_new_folder")) {
            _ = try await $0.newFolder(name: "n", parentFolderId: nil, displayOrder: nil)
        },
        Endpoint("updateFolder", .strict("rss_update_folder")) {
            _ = try await $0.updateFolder("f", RssFolderUpdate(name: "n"))
        },
        Endpoint("deleteFolder", .strict("rss_delete_folder")) { _ = try await $0.deleteFolder("f") },
        Endpoint("listItems", .strict("rss_list_items")) {
            _ = try await $0.listItems(scope: .all, filter: .all, order: .newest, limit: 10, cursor: nil)
        },
        Endpoint("syncItems", .strict("rss_list_items")) {
            _ = try await $0.syncItems(subscriptionId: "s", since: "", limit: 10)
        },
        Endpoint("syncItemStates", .strict("rss_list_items")) {
            _ = try await $0.syncItemStates(subscriptionId: "s", since: "", limit: 10)
        },
        Endpoint("getItem", .strict("rss_get_item")) { _ = try await $0.getItem(feedId: "f", sortKey: "k") },
        Endpoint("setItemState", .strict("rss_set_item_state")) {
            _ = try await $0.setItemState([RssItemStateChange(feedId: "f", sortKey: "k", isRead: true)])
        },
        Endpoint("markAllRead", .strict("rss_mark_all_read")) {
            _ = try await $0.markAllRead(scope: .all, watermark: nil)
        },
        Endpoint("importOpml", .strict("rss_opml_import")) { _ = try await $0.importOpml("<opml/>", folderId: nil) },
        Endpoint("exportOpml", .strict("rss_opml_export")) { _ = try await $0.exportOpml() },
    ]

    /// Calls `endpoint` against a client whose every request is answered
    /// 200 with `body`; nil when the call returned.
    private static func error(calling endpoint: Endpoint, replying body: String) async -> Error? {
        let transport = ScriptedHTTPTransport { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let client = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: transport
        )
        do {
            try await endpoint.call(client)
            return nil
        } catch {
            return error
        }
    }
}
