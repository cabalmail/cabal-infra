import XCTest
import CabalmailKit
@testable import CabalmailUI

// Regression coverage for issue #2102, driven the way the verification pass
// drove it: the shipped `pushDraftToServer` over a transport that answers
// `/save_draft` with a 200 the client cannot parse, reading what reaches the
// wire rather than what the model believes.
//
// Measured before the fix (stage `3ea56647`): the first call returned false
// with "Couldn't save draft: Couldn't read the server's reply." on screen,
// `serverDraftRef` stayed at the resumed `uid: 625`, and the `replaces_uid`
// of every save that reached the wire was `[625, 625]` — the second save
// quoting the UID the first had already retired, so it replaced nothing and
// the user was left with two copies of one draft.
//
// `/save_draft` APPENDs the new copy and expunges the superseded one before
// it builds its reply, so that 200 was a save that landed with only its
// coordinates lost. The client now finds the copy it wrote by the Message-ID
// it stamped on it (`CabalmailClientSaveDraftRecoveryTests` covers the
// resolution itself); these cases pin what the compose session does with it.
@MainActor
final class DraftSaveUnreadableReplyTests: XCTestCase {

    /// Both bodies the report named, and the reading that matters for each:
    /// the window closes, nothing is on screen, and the session is holding
    /// the copy the server actually has.
    func testACommittedSaveWithAnUnreadableReplyIsNotAFailedSave() async throws {
        for body in ["", "<html><body>502 Bad Gateway</body></html>"] {
            let http = SaveDraftTransport(reply: body, savedCopyUid: 701, uidValidity: 9)
            let model = try TestFixtures.makeComposeModel(transport: http)
            model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

            let closed = await model.pushDraftToServer(message())

            XCTAssertTrue(closed, "the draft is on the server, so the window may close (\(body.debugDescription))")
            XCTAssertNil(model.errorMessage, "nothing failed (\(body.debugDescription))")
            XCTAssertEqual(
                model.serverDraftRef, DraftServerRef(uid: 701, uidValidity: 9),
                "the session adopts the copy the save wrote (\(body.debugDescription))"
            )
        }
    }

    /// The finding itself: the next save must not quote the UID this one
    /// retired. `[625, 701]` is the inversion of the measured `[625, 625]`.
    func testTheNextSaveReplacesTheCopyTheLastOneWrote() async throws {
        let http = SaveDraftTransport(reply: "", savedCopyUid: 701, uidValidity: 9)
        let model = try TestFixtures.makeComposeModel(transport: http)
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        _ = await model.pushDraftToServer(message())
        _ = await model.pushDraftToServer(message())

        let quoted = await http.replacesUids
        XCTAssertEqual(quoted, [625, 701],
                       "the second save replaces 701, not the retired 625")
    }

    /// The retired copy is still reported to an open Drafts list: its row is
    /// a phantom whichever way the reply read (#1071).
    func testTheRetiredCopyIsStillReportedToTheList() async throws {
        let http = SaveDraftTransport(reply: "", savedCopyUid: 701, uidValidity: 9)
        let model = try TestFixtures.makeComposeModel(transport: http)
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        _ = await model.pushDraftToServer(message())

        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [625], survivingUID: 701)
        )
    }

    /// When the copy cannot be resolved at all, the save still landed — but
    /// the session must drop the ref it was holding, or the next save quotes
    /// a UID the server no longer has and the duplicate is back. Nil is the
    /// documented coordinates-unknown state: the next save creates a fresh
    /// copy, and the list is told to let its reader go rather than repoint
    /// at a phantom.
    func testAnUnresolvableSaveDropsTheRetiredRefRatherThanKeepingIt() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        model.adoptServerDraftRef(nil)

        XCTAssertNil(model.serverDraftRef)
        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [625], survivingUID: nil)
        )
    }

    /// Control: a decodable 200 behaves exactly as it always did, and this
    /// is the arm that proves the transport, the adopt and the
    /// `replaces_uid` plumbing all work — so the arms above are about the
    /// unreadable reply and not about this harness.
    func testADecodableReplyIsUnchanged() async throws {
        let http = SaveDraftTransport(reply: nil, savedCopyUid: 701, uidValidity: 9)
        let model = try TestFixtures.makeComposeModel(transport: http)
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        let closed = await model.pushDraftToServer(message())
        _ = await model.pushDraftToServer(message())

        XCTAssertTrue(closed)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.serverDraftRef, DraftServerRef(uid: 701, uidValidity: 9))
        let quoted = await http.replacesUids
        XCTAssertEqual(quoted, [625, 701])
    }

    /// Control the other way: a save that never reached the Lambda is still
    /// a failed save — the window stays up with the failure on screen and
    /// the ref is untouched. Only a 200 says the copy was written.
    func testATransportFailureStillKeepsTheWindowUp() async throws {
        let model = try TestFixtures.makeComposeModel(transport: UnreachableTransport())
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        let closed = await model.pushDraftToServer(message())

        XCTAssertFalse(closed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.serverDraftRef, DraftServerRef(uid: 625, uidValidity: 9))
    }

    private func message() -> OutgoingMessage {
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
}

// MARK: - Transport
//
// Routes by path and records what each `/save_draft` quoted. One copy lives
// in `Drafts`, carrying the Message-ID the save it answers put on the wire —
// which is what the recovery has to match.

private actor SaveDraftTransport: HTTPTransport {
    /// The unreadable body to answer `/save_draft` with; nil answers a
    /// normal, decodable reply instead.
    private let reply: String?
    private let savedCopyUid: UInt32
    private let uidValidity: UInt32
    private(set) var replacesUids: [Int] = []
    private var savedMessageId: String?

    init(reply: String?, savedCopyUid: UInt32, uidValidity: UInt32) {
        self.reply = reply
        self.savedCopyUid = savedCopyUid
        self.uidValidity = uidValidity
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = "/" + (request.url?.lastPathComponent ?? "")
        switch path {
        case "/save_draft":
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            replacesUids.append((body?["replaces_uid"] as? Int) ?? 0)
            let headers = body?["other_headers"] as? [String: Any]
            savedMessageId = (headers?["message_id"] as? [String])?.first
            if let reply {
                return respond(reply, to: request)
            }
            return respond(
                """
                {"status":"saved","uid":\(savedCopyUid),"uidvalidity":\(uidValidity),"replaced":true}
                """,
                to: request
            )
        case "/folder_status":
            return respond(
                "{\"uid_validity\":\(uidValidity),\"messages\":1,\"unseen\":0,\"uid_next\":999}",
                to: request
            )
        case "/list_messages":
            return respond("{\"message_ids\":[\(savedCopyUid)]}", to: request)
        case "/list_envelopes":
            let id = savedMessageId.map { "[\"\($0)\"]" } ?? "null"
            return respond(
                """
                {"envelopes":{"\(savedCopyUid)":{"id":\(savedCopyUid),"date":null,\
                "subject":"wip draft","from":[],"to":[],"cc":[],"flags":["\\\\Draft"],\
                "message_id":\(id)}}}
                """,
                to: request
            )
        default:
            throw CabalmailError.transport("unexpected request to \(path)")
        }
    }

    private func respond(_ body: String, to request: URLRequest) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
