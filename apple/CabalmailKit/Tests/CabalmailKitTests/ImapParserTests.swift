import XCTest
@testable import CabalmailKit

final class ImapParserTests: XCTestCase {
    func testParseTaggedCompletion() {
        let line = Data("A123 OK LOGIN completed".utf8)
        let response = ImapParser.parse(line: line, literals: [])
        guard case let .completion(tag, status, text) = response else {
            return XCTFail("Expected completion, got \(response)")
        }
        XCTAssertEqual(tag, "A123")
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(text, "LOGIN completed")
    }

    func testParseUntaggedStatus() {
        let line = Data("* OK Dovecot ready".utf8)
        let response = ImapParser.parse(line: line, literals: [])
        guard case let .status(code, text) = response else {
            return XCTFail("Expected status, got \(response)")
        }
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(text, "Dovecot ready")
    }

    func testParseExists() {
        let line = Data("* 42 EXISTS".utf8)
        if case .exists(let n) = ImapParser.parse(line: line, literals: []) {
            XCTAssertEqual(n, 42)
        } else {
            XCTFail()
        }
    }

    func testParseListWithAttributesAndDelimiter() {
        let line = Data(#"* LIST (\HasChildren) "." "Archive""#.utf8)
        if case let .list(attrs, delim, mbox) = ImapParser.parse(line: line, literals: []) {
            XCTAssertEqual(attrs, ["\\HasChildren"])
            XCTAssertEqual(delim, ".")
            XCTAssertEqual(mbox, "Archive")
        } else {
            XCTFail()
        }
    }

    func testParseStatusAttributes() {
        let line = Data(#"* STATUS "INBOX" (MESSAGES 12 UNSEEN 3 UIDVALIDITY 5 UIDNEXT 13)"#.utf8)
        if case let .status2(mbox, attrs) = ImapParser.parse(line: line, literals: []) {
            XCTAssertEqual(mbox, "INBOX")
            XCTAssertEqual(attrs["MESSAGES"], 12)
            XCTAssertEqual(attrs["UNSEEN"], 3)
            XCTAssertEqual(attrs["UIDVALIDITY"], 5)
            XCTAssertEqual(attrs["UIDNEXT"], 13)
        } else {
            XCTFail()
        }
    }

    func testParseSearch() {
        let line = Data("* SEARCH 1 7 42 99".utf8)
        if case let .search(ids) = ImapParser.parse(line: line, literals: []) {
            XCTAssertEqual(ids, [1, 7, 42, 99])
        } else {
            XCTFail()
        }
    }

    func testFetchWithLiteralBody() {
        // Line with a marker byte where the literal lives.
        var line = Data("* 1 FETCH (UID 7 BODY[] ".utf8)
        line.append(ImapTokenizer.literalMarker)
        line.append(Data(")".utf8))
        let literalBody = Data("Hello\r\n".utf8)
        let response = ImapParser.parse(line: line, literals: [literalBody])
        guard case let .fetch(_, attrs) = response else {
            return XCTFail("Expected fetch, got \(response)")
        }
        XCTAssertEqual(attrs.uid, 7)
        XCTAssertEqual(attrs.body, literalBody)
    }

    func testContinuationResponse() {
        let line = Data("+ OK continue".utf8)
        if case let .continuation(text) = ImapParser.parse(line: line, literals: []) {
            XCTAssertEqual(text, "OK continue")
        } else {
            XCTFail()
        }
    }
}
