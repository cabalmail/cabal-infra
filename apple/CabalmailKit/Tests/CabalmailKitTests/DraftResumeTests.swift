import XCTest
@testable import CabalmailKit

final class MessageIdsTests: XCTestCase {
    func testParsesSingleId() {
        XCTAssertEqual(MessageIds.parse("<a@x.example>"), ["<a@x.example>"])
    }

    func testParsesMultipleIdsWithNoise() {
        XCTAssertEqual(
            MessageIds.parse("<a@x> (comment) <b@y>\t<c@z>"),
            ["<a@x>", "<b@y>", "<c@z>"]
        )
    }

    func testNilAndTokenFreeInputYieldEmpty() {
        XCTAssertEqual(MessageIds.parse(nil), [])
        XCTAssertEqual(MessageIds.parse("no ids here"), [])
        XCTAssertEqual(MessageIds.parse("<>"), [])
    }
}

final class DraftResumeTests: XCTestCase {
    private func makeEnvelope() -> Envelope {
        Envelope(
            uid: 42,
            subject: "wip draft",
            from: [EmailAddress(name: nil, mailbox: "alice", host: "mail.example")],
            to: [EmailAddress(name: nil, mailbox: "bob", host: "x.example")],
            cc: [EmailAddress(name: nil, mailbox: "carol", host: "y.example")]
        )
    }

    private func makeHeaders() -> [MimeHeader] {
        [
            MimeHeader(name: "Bcc", value: #"dave@z.example, "Erin" <erin@w.example>"#),
            MimeHeader(name: "In-Reply-To", value: "<parent@x.example>"),
            MimeHeader(name: "References", value: "<root@x.example> <parent@x.example>"),
        ]
    }

    func testSeedCarriesRecipientsSubjectAndServerRef() {
        let draft = DraftResume.seed(
            envelope: makeEnvelope(),
            headers: makeHeaders(),
            plainText: "the markdown source",
            htmlBody: "<p>the markdown source</p>",
            serverRef: DraftServerRef(uid: 42, uidValidity: 99)
        )
        XCTAssertEqual(draft.fromAddress, "alice@mail.example")
        XCTAssertEqual(draft.to, ["bob@x.example"])
        XCTAssertEqual(draft.cc, ["carol@y.example"])
        XCTAssertEqual(draft.bcc, ["dave@z.example", "erin@w.example"])
        XCTAssertEqual(draft.subject, "wip draft")
        XCTAssertEqual(draft.body, "the markdown source")
        XCTAssertEqual(draft.inReplyTo, "parent@x.example")
        XCTAssertEqual(draft.references, ["root@x.example", "parent@x.example"])
        XCTAssertEqual(draft.serverUid, 42)
        XCTAssertEqual(draft.serverUidValidity, 99)
        XCTAssertEqual(draft.serverRef, DraftServerRef(uid: 42, uidValidity: 99))
        XCTAssertEqual(draft.composeIntent, .new)
    }

    func testBodyPrefersPlainTextOverHtml() {
        XCTAssertEqual(DraftResume.body(plainText: "md", htmlBody: "<p>x</p>"), "md")
    }

    func testBodyFallsBackToHtmlForHtmlOnlyDrafts() {
        // Foreign-client draft with no text/plain part: the raw HTML rides
        // the Markdown buffer (Markdown passes inline HTML through), so
        // resuming never loses content.
        XCTAssertEqual(DraftResume.body(plainText: "  \n", htmlBody: "<p>x</p>"), "<p>x</p>")
        XCTAssertEqual(DraftResume.body(plainText: nil, htmlBody: "<p>x</p>"), "<p>x</p>")
        XCTAssertEqual(DraftResume.body(plainText: nil, htmlBody: nil), "")
    }

    func testAddressListHandlesBareAndBracketedForms() {
        XCTAssertEqual(
            DraftResume.addressList(#"a@x, "B C" <b@y>, <c@z>"#),
            ["a@x", "b@y", "c@z"]
        )
        XCTAssertEqual(DraftResume.addressList(nil), [])
        XCTAssertEqual(DraftResume.addressList("  "), [])
    }

    func testMissingServerRefLeavesCoordinatesNil() {
        let draft = DraftResume.seed(
            envelope: makeEnvelope(),
            headers: [],
            plainText: "body",
            htmlBody: nil,
            serverRef: nil
        )
        XCTAssertNil(draft.serverUid)
        XCTAssertNil(draft.serverUidValidity)
        XCTAssertNil(draft.serverRef)
        XCTAssertEqual(draft.bcc, [])
        XCTAssertNil(draft.inReplyTo)
        XCTAssertEqual(draft.references, [])
    }
}
