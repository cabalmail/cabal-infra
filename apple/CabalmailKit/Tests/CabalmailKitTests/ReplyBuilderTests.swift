import XCTest
@testable import CabalmailKit

final class ReplyBuilderTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_717_171_717)
    private let clock: @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_717_171_717)
    }

    // MARK: - Subject prefixing

    func testReplyPrefixesSubject() {
        XCTAssertEqual(ReplyBuilder.prefixedSubject("Hello", mode: .reply), "Re: Hello")
    }

    func testReplyIsIdempotentOnExistingRePrefix() {
        XCTAssertEqual(ReplyBuilder.prefixedSubject("Re: Hello", mode: .reply), "Re: Hello")
        XCTAssertEqual(ReplyBuilder.prefixedSubject("RE: Hello", mode: .reply), "RE: Hello")
    }

    func testForwardPrefixesSubject() {
        XCTAssertEqual(ReplyBuilder.prefixedSubject("Hello", mode: .forward), "Fwd: Hello")
    }

    func testReplyHandlesEmptySubject() {
        XCTAssertEqual(ReplyBuilder.prefixedSubject("", mode: .reply), "Re: ")
    }

    // MARK: - From selection

    func testReplyDefaultsFromToOriginalAddressee() {
        // Cabalmail idiom: the address the original was sent to was minted
        // specifically for this correspondent, so replying should reuse it.
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")]
        )
        let owned = [
            Address(address: "alice@mail.example.com", subdomain: "mail", tld: "example.com")
        ]
        let draft = ReplyBuilder.build(
            from: envelope,
            body: nil,
            mode: .reply,
            userAddresses: owned,
            now: clock
        )
        XCTAssertEqual(draft.fromAddress, "alice@mail.example.com")
    }

    func testReplyFromIsNilWhenNoOwnedAddressMatched() {
        // No default-from available → UI falls through to the
        // "Create new address…" inline flow, which is the intended primary
        // path anyway.
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")]
        )
        let draft = ReplyBuilder.build(
            from: envelope,
            body: nil,
            mode: .reply,
            userAddresses: [],
            now: clock
        )
        XCTAssertNil(draft.fromAddress)
    }

    func testReplyFromIgnoresCaseMismatch() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("Alice", "Mail.Example.COM")]
        )
        let owned = [
            Address(address: "alice@mail.example.com", subdomain: "mail", tld: "example.com")
        ]
        let draft = ReplyBuilder.build(
            from: envelope,
            body: nil,
            mode: .reply,
            userAddresses: owned,
            now: clock
        )
        XCTAssertEqual(draft.fromAddress, "alice@mail.example.com")
    }

    // MARK: - Recipient lists

    func testReplyToListIsAuthor() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com"), ("carol", "x.example.com")]
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .reply, userAddresses: [], now: clock
        )
        XCTAssertEqual(draft.to, ["bob@example.com"])
        XCTAssertEqual(draft.cc, [])
    }

    func testReplyAllIncludesAllRecipientsExcludingUser() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com"), ("carol", "other.example")],
            cc: [("dave", "three.example")]
        )
        let owned = [
            Address(address: "alice@mail.example.com", subdomain: "mail", tld: "example.com")
        ]
        let draft = ReplyBuilder.build(
            from: envelope,
            body: nil,
            mode: .replyAll,
            userAddresses: owned,
            now: clock
        )
        XCTAssertEqual(draft.to, ["bob@example.com"])
        XCTAssertTrue(draft.cc.contains("carol@other.example"))
        XCTAssertTrue(draft.cc.contains("dave@three.example"))
        XCTAssertFalse(draft.cc.contains("alice@mail.example.com"))
    }

    func testReplyAllUsesReplyToOverFromWhenPresent() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            replyTo: [("bob-list", "example.com")],
            to: [("alice", "mail.example.com")]
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .replyAll, userAddresses: [], now: clock
        )
        XCTAssertEqual(draft.to, ["bob-list@example.com"])
    }

    func testForwardHasNoRecipients() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")]
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .forward, userAddresses: [], now: clock
        )
        XCTAssertTrue(draft.to.isEmpty)
        XCTAssertTrue(draft.cc.isEmpty)
    }

    // MARK: - Quoting

    func testReplyBodyQuotesOriginalWithAttribution() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")],
            subject: "Proposal",
            date: fixedDate
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: "Line 1\nLine 2", mode: .reply, userAddresses: [], now: clock
        )
        XCTAssertTrue(draft.body.contains("> Line 1"))
        XCTAssertTrue(draft.body.contains("> Line 2"))
        XCTAssertTrue(draft.body.contains(" wrote:"))
    }

    func testForwardBodyUsesBannerNotPrefixQuote() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")],
            subject: "Proposal",
            date: fixedDate
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: "Original body", mode: .forward, userAddresses: [], now: clock
        )
        XCTAssertTrue(draft.body.contains("Forwarded message"))
        XCTAssertTrue(draft.body.contains("Original body"))
        XCTAssertFalse(draft.body.contains("> Original"))
    }

    func testReplyWithoutBodyProducesEmptyQuote() {
        let envelope = makeEnvelope(from: [("bob", "example.com")], subject: "Hi")
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .reply, userAddresses: [], now: clock
        )
        XCTAssertEqual(draft.body, "")
    }

    // MARK: - Threading

    func testReplyThreadingHeaders() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            messageId: "<m-1@example.com>",
            inReplyTo: "<m-0@example.com>"
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .reply, userAddresses: [], now: clock
        )
        XCTAssertEqual(draft.inReplyTo, "m-1@example.com")
        XCTAssertEqual(draft.references, ["m-0@example.com", "m-1@example.com"])
    }

    func testForwardHasNoThreadingHeaders() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            messageId: "<m-1@example.com>",
            inReplyTo: "<m-0@example.com>"
        )
        let draft = ReplyBuilder.build(
            from: envelope, body: nil, mode: .forward, userAddresses: [], now: clock
        )
        XCTAssertNil(draft.inReplyTo)
        XCTAssertTrue(draft.references.isEmpty)
    }

    // MARK: - Integration: ReplyBuilder → OutgoingMessage → MessageBuilder

    func testReplyBuilderOutputFeedsMessageBuilderWithThreadingHeaders() {
        let envelope = makeEnvelope(
            from: [("bob", "example.com")],
            to: [("alice", "mail.example.com")],
            subject: "Proposal",
            messageId: "<orig@example.com>"
        )
        let owned = [
            Address(address: "alice@mail.example.com", subdomain: "mail", tld: "example.com")
        ]
        let draft = ReplyBuilder.build(
            from: envelope, body: "Hi", mode: .reply, userAddresses: owned, now: clock
        )
        guard let fromAddress = draft.fromAddress,
              let from = EmailAddress(parsing: fromAddress) else {
            return XCTFail("expected default from")
        }
        let recipients = draft.to.compactMap(EmailAddress.init(parsing:))
        let message = OutgoingMessage(
            from: from,
            to: recipients,
            subject: draft.subject,
            textBody: draft.body,
            inReplyTo: draft.inReplyTo,
            references: draft.references
        )
        let wire = MessageBuilder.build(message, messageID: "reply@example.com", date: fixedDate)
        let text = String(data: wire, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("In-Reply-To: <orig@example.com>"))
        XCTAssertTrue(text.contains("References: <orig@example.com>"))
        XCTAssertTrue(text.contains("Subject: Re: Proposal"))
    }

    // MARK: - Helpers

    private func makeEnvelope(
        from: [(String, String)] = [],
        replyTo: [(String, String)] = [],
        to: [(String, String)] = [],
        cc: [(String, String)] = [],
        subject: String? = nil,
        date: Date? = nil,
        messageId: String? = nil,
        inReplyTo: String? = nil
    ) -> Envelope {
        Envelope(
            uid: 1,
            messageId: messageId,
            date: date,
            subject: subject,
            from: from.map { EmailAddress(name: nil, mailbox: $0.0, host: $0.1) },
            replyTo: replyTo.map { EmailAddress(name: nil, mailbox: $0.0, host: $0.1) },
            to: to.map { EmailAddress(name: nil, mailbox: $0.0, host: $0.1) },
            cc: cc.map { EmailAddress(name: nil, mailbox: $0.0, host: $0.1) },
            inReplyTo: inReplyTo,
            flags: [],
            internalDate: date,
            size: nil,
            hasAttachments: false
        )
    }
}

// MARK: - EmailAddress parsing bridge

// `EmailAddress.init(parsing:)` lives in the app target; a narrower copy
// here keeps the kit-level test self-contained (no dependency on the app).
private extension EmailAddress {
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return nil }
        let mailbox = String(trimmed[..<atIndex])
        let host = String(trimmed[trimmed.index(after: atIndex)...])
        guard !mailbox.isEmpty, !host.isEmpty else { return nil }
        self.init(name: nil, mailbox: mailbox, host: host)
    }
}
