import XCTest
@testable import CabalmailKit

/// Issue #2102: `/save_draft` APPENDs the new copy and expunges the one it
/// supersedes *before* it builds its reply, so a 200 whose body won't decode
/// is a save that landed with only its coordinates lost. `saveDraft` threw
/// on it, the compose session read that as a failed save and went on quoting
/// the UID the save had already retired, and the next save replaced nothing
/// — leaving the user two copies of one draft.
///
/// The recovery is identity, not recency: the client stamps a fresh UUID
/// Message-ID on every save and the Lambda writes that header verbatim, so
/// exactly one copy in `Drafts` can carry it. These drive the real
/// `CabalmailClient.saveDraft` over a transport that answers `/save_draft`
/// with bodies it cannot parse, and read the ref that comes back.
final class CabalmailClientSaveDraftRecoveryTests: XCTestCase {

    /// Both shapes the report named: a 200 with no body at all, and an HTML
    /// error page from something in the path.
    private static let unreadableBodies = ["", "<html><body>502 Bad Gateway</body></html>"]

    // MARK: - The fix

    func testAnUnreadable200ResolvesTheCopyTheSaveWrote() async throws {
        for body in Self.unreadableBodies {
            let drafts = DraftsFolder(uidValidity: 9, copies: [
                (uid: 701, messageId: "<probe-2102@cabalmail.example>"),
                (uid: 640, messageId: "<someone-elses@cabalmail.example>"),
            ])
            let http = RoutedTransport(saveDraftReply: body, drafts: drafts)
            let client = try makeClient(transport: http)

            let ref = try await client.saveDraft(
                message(messageId: "<probe-2102@cabalmail.example>"),
                replacing: DraftServerRef(uid: 625, uidValidity: 9)
            )

            XCTAssertEqual(
                ref, DraftServerRef(uid: 701, uidValidity: 9),
                "the save committed, so its copy's coordinates are the answer (body: \(body.debugDescription))"
            )
            let paths = await http.paths
            XCTAssertEqual(
                paths, ["/save_draft", "/folder_status", "/list_messages", "/list_envelopes"],
                "the recovery reads STATUS for UIDVALIDITY, then the Drafts head, then its envelopes"
            )
        }
    }

    /// The load-bearing half: `/list_envelopes` hands its rows back sorted
    /// by UID descending, so a resolver that took the newest copy would
    /// answer 999 here. Only the Message-ID picks 640.
    func testTheCopyIsFoundByMessageIdAndNotByBeingTheNewest() async throws {
        let drafts = DraftsFolder(uidValidity: 9, copies: [
            (uid: 999, messageId: "<another-device@cabalmail.example>"),
            (uid: 640, messageId: "<probe-2102@cabalmail.example>"),
        ])
        let http = RoutedTransport(saveDraftReply: "", drafts: drafts)
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(message(messageId: "<probe-2102@cabalmail.example>"))

        XCTAssertEqual(ref, DraftServerRef(uid: 640, uidValidity: 9))
    }

    /// Production never sets a Message-ID on the compose buffer — `saveDraft`
    /// mints one. The recovery has to match *that* id, so the arm that
    /// matters is the one where the test never names it: the transport
    /// answers `/list_envelopes` with whatever went out on `/save_draft`.
    func testTheMintedMessageIdIsTheOneTheRecoveryMatches() async throws {
        let http = RoutedTransport(saveDraftReply: "", drafts: .echoingTheSavedMessageId(uid: 701, uidValidity: 9))
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(message(messageId: nil))

        XCTAssertEqual(ref, DraftServerRef(uid: 701, uidValidity: 9))
        let stamped = await http.savedMessageId
        XCTAssertNotNil(stamped, "every save goes out with a Message-ID")
        XCTAssertTrue(stamped?.hasSuffix("@cabalmail.example>") == true, "minted on the sender's host")
    }

    // MARK: - What it must not do

    /// No match is "saved, coordinates unknown" — nil, which `saveDraft`
    /// already documents and which makes the caller drop the retired ref.
    /// It is not a throw: the save committed.
    func testNoMatchingCopyIsNilRatherThanAFailedSave() async throws {
        let drafts = DraftsFolder(uidValidity: 9, copies: [
            (uid: 701, messageId: "<someone-elses@cabalmail.example>"),
        ])
        let http = RoutedTransport(saveDraftReply: "", drafts: drafts)
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(message(messageId: "<probe-2102@cabalmail.example>"))

        XCTAssertNil(ref)
    }

    /// Same when the recovery's own reads fail. Turning a landed save back
    /// into a reported failure is the defect, so the read's trouble cannot
    /// escape.
    func testAFailedRecoveryReadIsNilRatherThanAFailedSave() async throws {
        let http = RoutedTransport(saveDraftReply: "", drafts: .unreachable)
        let client = try makeClient(transport: http)

        let ref = try await client.saveDraft(message(messageId: "<probe-2102@cabalmail.example>"))

        XCTAssertNil(ref)
        let paths = await http.paths
        XCTAssertEqual(paths.count, 2, "it tried the first read and stopped there")
    }

    /// Control: a reply that *doesn't* decode because the transport refused
    /// the request at all is still a failure, and still throws. Only a 200
    /// is evidence the Lambda got as far as committing.
    func testATransportFailureStillThrows() async throws {
        let http = RoutedTransport(saveDraftReply: nil, drafts: .unreachable)
        let client = try makeClient(transport: http)

        do {
            _ = try await client.saveDraft(message(messageId: "<probe-2102@cabalmail.example>"))
            XCTFail("a save that never reached the Lambda is a failed save")
        } catch is CabalmailError {
            // Expected.
        }
    }

    private func configuration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    private func makeClient(transport: HTTPTransport) throws -> CabalmailClient {
        let config = configuration()
        let auth = StubAuthService()
        let api = URLSessionApiClient(configuration: config, authService: auth, transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: api,
            imapClient: ApiBackedImapClient(api: api, host: config.imapHost),
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: tmp.appendingPathComponent("e")),
            bodyCache: try MessageBodyCache(directory: tmp.appendingPathComponent("b")),
            draftStore: try DraftStore(directory: tmp.appendingPathComponent("d")),
            outbox: try Outbox(directory: tmp.appendingPathComponent("o"))
        )
    }

    private func message(messageId: String?) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "cabalmail.example"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "cabalmail.example")],
            cc: [],
            bcc: [],
            subject: "wip draft",
            textBody: "still thinking",
            htmlBody: "<p>still thinking</p>",
            messageId: messageId
        )
    }
}

// MARK: - Fixtures
//
// At file scope, `private`: a test class carrying its own doubles runs into
// SwiftLint's `type_body_length` cap, and the house answer is to move them
// out rather than to write thinner tests.

private struct DraftsFolder: Sendable {
    var uidValidity: UInt32?
    /// Newest first, as `/list_envelopes` hands them back.
    var copies: [(uid: UInt32, messageId: String?)] = []
    /// Answer `/list_envelopes` with the id that went out on the save.
    var echoesSavedMessageId: UInt32?
    var reachable = true

    static let unreachable = DraftsFolder(uidValidity: nil, reachable: false)

    static func echoingTheSavedMessageId(uid: UInt32, uidValidity: UInt32) -> DraftsFolder {
        DraftsFolder(uidValidity: uidValidity, echoesSavedMessageId: uid)
    }
}

/// Routes by path, so the recovery's three reads can be answered without
/// depending on the order a FIFO queue would impose.
private actor RoutedTransport: HTTPTransport {
    private let saveDraftReply: String?
    private let drafts: DraftsFolder
    private(set) var paths: [String] = []
    private(set) var savedMessageId: String?
    private(set) var replacesUids: [Int] = []

    init(saveDraftReply: String?, drafts: DraftsFolder) {
        self.saveDraftReply = saveDraftReply
        self.drafts = drafts
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = "/" + (request.url?.lastPathComponent ?? "")
        paths.append(path)
        switch path {
        case "/save_draft":
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let headers = body?["other_headers"] as? [String: Any]
            savedMessageId = (headers?["message_id"] as? [String])?.first
            if let replaces = body?["replaces_uid"] as? Int { replacesUids.append(replaces) }
            guard let saveDraftReply else { throw CabalmailError.transport("refused") }
            return try reply(saveDraftReply, for: request)
        case "/folder_status":
            guard drafts.reachable else { throw CabalmailError.transport("refused") }
            let validity = drafts.uidValidity.map { "\"uid_validity\":\($0)," } ?? ""
            return try reply("{\(validity)\"messages\":2,\"unseen\":0,\"uid_next\":1000}", for: request)
        case "/list_messages":
            let ids = resolvedCopies().map { String($0.uid) }.joined(separator: ",")
            return try reply("{\"message_ids\":[\(ids)]}", for: request)
        case "/list_envelopes":
            let rows = resolvedCopies().map { copy in
                let id = copy.messageId.map { "[\"\($0)\"]" } ?? "null"
                return """
                "\(copy.uid)":{"id":\(copy.uid),"date":null,"subject":"wip","from":[],\
                "to":[],"cc":[],"flags":["\\\\Draft"],"message_id":\(id)}
                """
            }
            return try reply("{\"envelopes\":{\(rows.joined(separator: ","))}}", for: request)
        default:
            throw CabalmailError.transport("unexpected request to \(path)")
        }
    }

    private func resolvedCopies() -> [(uid: UInt32, messageId: String?)] {
        if let uid = drafts.echoesSavedMessageId {
            return [(uid: uid, messageId: savedMessageId)]
        }
        return drafts.copies
    }

    private func reply(_ body: String, for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
