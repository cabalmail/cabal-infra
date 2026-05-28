import XCTest
@testable import CabalmailKit

final class MailtoURLTests: XCTestCase {

    private func parse(_ string: String) -> MailtoURL? {
        guard let url = URL(string: string) else { return nil }
        return MailtoURL(url)
    }

    // MARK: - Scheme guard

    func testNonMailtoSchemeReturnsNil() {
        XCTAssertNil(parse("https://example.com"))
        XCTAssertNil(parse("http://foo@bar.com"))
        XCTAssertNil(parse("tel:+15551234567"))
    }

    func testEmptyMailtoIsValidWithNoRecipients() {
        let parsed = parse("mailto:")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.to, [])
        XCTAssertEqual(parsed?.cc, [])
        XCTAssertEqual(parsed?.bcc, [])
        XCTAssertEqual(parsed?.subject, "")
        XCTAssertEqual(parsed?.body, "")
    }

    // MARK: - Recipients in the path

    func testSingleToInPath() {
        let parsed = parse("mailto:foo@bar.com")
        XCTAssertEqual(parsed?.to, ["foo@bar.com"])
    }

    func testMultipleToInPath() {
        let parsed = parse("mailto:foo@bar.com,baz@qux.com")
        XCTAssertEqual(parsed?.to, ["foo@bar.com", "baz@qux.com"])
    }

    func testPathRecipientsTrimWhitespace() {
        let parsed = parse("mailto:foo@bar.com,%20baz@qux.com")
        XCTAssertEqual(parsed?.to, ["foo@bar.com", "baz@qux.com"])
    }

    // MARK: - Query parameter recipients

    func testToInQueryParameter() {
        let parsed = parse("mailto:?to=foo@bar.com")
        XCTAssertEqual(parsed?.to, ["foo@bar.com"])
    }

    func testPathAndQueryToConcatenate() {
        let parsed = parse("mailto:foo@bar.com?to=baz@qux.com")
        XCTAssertEqual(parsed?.to, ["foo@bar.com", "baz@qux.com"])
    }

    func testCcAndBcc() {
        let parsed = parse("mailto:?cc=cc@x.com&bcc=bcc@y.com")
        XCTAssertEqual(parsed?.cc, ["cc@x.com"])
        XCTAssertEqual(parsed?.bcc, ["bcc@y.com"])
    }

    func testMultiValueCc() {
        let parsed = parse("mailto:?cc=a@x.com,b@y.com")
        XCTAssertEqual(parsed?.cc, ["a@x.com", "b@y.com"])
    }

    // MARK: - Subject and body

    func testSubjectPercentDecoded() {
        let parsed = parse("mailto:foo@bar.com?subject=Hi%20there")
        XCTAssertEqual(parsed?.subject, "Hi there")
    }

    func testBodyPercentDecodedAndPreservesNewlines() {
        let parsed = parse("mailto:foo@bar.com?body=line1%0D%0Aline2")
        XCTAssertEqual(parsed?.body, "line1\r\nline2")
    }

    func testFullForm() {
        let parsed = parse(
            "mailto:alice@x.com,bob@y.com" +
            "?cc=cc@z.com" +
            "&bcc=hidden@w.com" +
            "&subject=Hello&body=World"
        )
        XCTAssertEqual(parsed?.to, ["alice@x.com", "bob@y.com"])
        XCTAssertEqual(parsed?.cc, ["cc@z.com"])
        XCTAssertEqual(parsed?.bcc, ["hidden@w.com"])
        XCTAssertEqual(parsed?.subject, "Hello")
        XCTAssertEqual(parsed?.body, "World")
    }

    // MARK: - Unknown headers are dropped

    func testUnknownHeadersIgnored() {
        let parsed = parse("mailto:foo@bar.com?in-reply-to=<x@y>&references=<a@b>")
        XCTAssertEqual(parsed?.to, ["foo@bar.com"])
        XCTAssertEqual(parsed?.cc, [])
        XCTAssertEqual(parsed?.subject, "")
        XCTAssertEqual(parsed?.body, "")
    }

    // MARK: - Case folding of the scheme

    func testUppercaseSchemeAccepted() {
        let parsed = parse("MAILTO:foo@bar.com?subject=Hi")
        XCTAssertEqual(parsed?.to, ["foo@bar.com"])
        XCTAssertEqual(parsed?.subject, "Hi")
    }

    // MARK: - Header name case folding

    func testQueryParamNamesAreCaseInsensitive() {
        let parsed = parse("mailto:?CC=a@x.com&SUBJECT=Hi")
        XCTAssertEqual(parsed?.cc, ["a@x.com"])
        XCTAssertEqual(parsed?.subject, "Hi")
    }

    // MARK: - Draft conversion

    func testDraftConversion() {
        let mailto = MailtoURL(
            to: ["a@x.com"],
            cc: ["c@x.com"],
            bcc: ["b@x.com"],
            subject: "Hi",
            body: "Hello"
        )
        let draft = mailto.draft()
        XCTAssertEqual(draft.to, ["a@x.com"])
        XCTAssertEqual(draft.cc, ["c@x.com"])
        XCTAssertEqual(draft.bcc, ["b@x.com"])
        XCTAssertEqual(draft.subject, "Hi")
        XCTAssertEqual(draft.body, "Hello")
        XCTAssertEqual(draft.composeIntent, .new)
    }
}
