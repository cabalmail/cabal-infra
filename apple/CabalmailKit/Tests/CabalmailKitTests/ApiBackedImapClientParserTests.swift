import XCTest
@testable import CabalmailKit

final class ApiBackedImapClientParserTests: XCTestCase {
    func testMakeEnvelopeFlattensLambdaShape() {
        let raw = ApiEnvelope(
            id: 42,
            date: "2024-01-15 10:30:45+00:00",
            subject: "Hello",
            from: [#""Alice Smith" <alice@example.com>"#],
            to: ["bob@example.com", "undisclosed-recipients"],
            cc: [],
            flags: ["\\Seen", "\\Flagged", "Junk"],
            structure: .list([.string("text"), .string("plain")]),
            priority: nil
        )
        let env = ApiBackedImapClient.makeEnvelope(raw)
        XCTAssertEqual(env.uid, 42)
        XCTAssertEqual(env.subject, "Hello")
        XCTAssertEqual(env.from.first?.name, "Alice Smith")
        XCTAssertEqual(env.from.first?.displayName, "Alice Smith")
        XCTAssertEqual(env.from.first?.mailbox, "alice")
        XCTAssertEqual(env.from.first?.host, "example.com")
        XCTAssertEqual(env.to.count, 2)
        XCTAssertEqual(env.to[0].name, nil)
        XCTAssertEqual(env.to[0].mailbox, "bob")
        XCTAssertEqual(env.to[1].mailbox, "undisclosed-recipients")
        XCTAssertTrue(env.flags.contains(.seen))
        XCTAssertTrue(env.flags.contains(.flagged))
        XCTAssertTrue(env.flags.contains(.keyword("Junk")))
    }

    func testIsImportantMatchesReactRule() {
        XCTAssertTrue(ApiBackedImapClient.isImportant(priority: ["priority-1"]))
        XCTAssertTrue(ApiBackedImapClient.isImportant(priority: ["priority-2"]))
        XCTAssertTrue(ApiBackedImapClient.isImportant(priority: ["priority-1", "priority-3"]))
        XCTAssertFalse(ApiBackedImapClient.isImportant(priority: ["priority-3"]))
        XCTAssertFalse(ApiBackedImapClient.isImportant(priority: ["priority-4", "priority-5"]))
        XCTAssertFalse(ApiBackedImapClient.isImportant(priority: []))
        XCTAssertFalse(ApiBackedImapClient.isImportant(priority: nil))
    }

    func testMakeEnvelopePopulatesIsImportant() {
        let highPriority = ApiEnvelope(
            id: 1, date: nil, subject: nil, from: [], to: [], cc: [],
            flags: [], structure: nil, priority: ["priority-1"]
        )
        XCTAssertTrue(ApiBackedImapClient.makeEnvelope(highPriority).isImportant)

        let normalPriority = ApiEnvelope(
            id: 2, date: nil, subject: nil, from: [], to: [], cc: [],
            flags: [], structure: nil, priority: ["priority-3"]
        )
        XCTAssertFalse(ApiBackedImapClient.makeEnvelope(normalPriority).isImportant)
    }

    func testEnvelopeDecodesThreadingHeadersAndMakeEnvelopeCarriesThem() throws {
        // Wire shape from the Phase 1 Lambda: lists of angle-bracketed ids,
        // matching /fetch_message.
        let json = """
        {"id": 7, "date": null, "subject": "s", "from": [], "to": [], "cc": [],
         "flags": [], "struct": null, "priority": [],
         "message_id": ["<child@y.example>"],
         "in_reply_to": ["<parent@x.example>"],
         "references": ["<a@x.example>", "<parent@x.example>"]}
        """
        let raw = try JSONDecoder().decode(ApiEnvelope.self, from: Data(json.utf8))
        let env = ApiBackedImapClient.makeEnvelope(raw)
        XCTAssertEqual(env.messageId, "<child@y.example>")
        XCTAssertEqual(env.inReplyTo, "<parent@x.example>")
        XCTAssertEqual(env.references, ["<a@x.example>", "<parent@x.example>"])
    }

    func testEnvelopeWithoutThreadingFieldsStillDecodes() throws {
        // Payload from a Lambda predating the threading fields: additive
        // change, so the decoder must tolerate their absence.
        let json = """
        {"id": 7, "date": null, "subject": "s", "from": [], "to": [], "cc": [],
         "flags": [], "struct": null, "priority": []}
        """
        let raw = try JSONDecoder().decode(ApiEnvelope.self, from: Data(json.utf8))
        let env = ApiBackedImapClient.makeEnvelope(raw)
        XCTAssertNil(env.messageId)
        XCTAssertNil(env.inReplyTo)
        XCTAssertEqual(env.references, [])
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
        XCTAssertEqual(addr?.name, nil)
        XCTAssertEqual(addr?.mailbox, "alice")
        XCTAssertEqual(addr?.host, "example.com")

        let weird = ApiBackedImapClient.parseAddress("a@b@example.com")
        XCTAssertEqual(weird?.mailbox, "a@b")
        XCTAssertEqual(weird?.host, "example.com")

        let placeholder = ApiBackedImapClient.parseAddress("undisclosed-recipients")
        XCTAssertEqual(placeholder?.mailbox, "undisclosed-recipients")
        XCTAssertEqual(placeholder?.host, "")
    }

    func testParseAddressExtractsQuotedDisplayName() {
        let addr = ApiBackedImapClient.parseAddress(#""Alice Smith" <alice@example.com>"#)
        XCTAssertEqual(addr?.name, "Alice Smith")
        XCTAssertEqual(addr?.mailbox, "alice")
        XCTAssertEqual(addr?.host, "example.com")
    }

    func testParseAddressExtractsUnquotedDisplayName() {
        let addr = ApiBackedImapClient.parseAddress("Alice Smith <alice@example.com>")
        XCTAssertEqual(addr?.name, "Alice Smith")
        XCTAssertEqual(addr?.mailbox, "alice")
        XCTAssertEqual(addr?.host, "example.com")
    }

    func testParseAddressHandlesEmptyDisplayNameInAngleForm() {
        let addr = ApiBackedImapClient.parseAddress("<alice@example.com>")
        XCTAssertNil(addr?.name)
        XCTAssertEqual(addr?.mailbox, "alice")
        XCTAssertEqual(addr?.host, "example.com")
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
}
