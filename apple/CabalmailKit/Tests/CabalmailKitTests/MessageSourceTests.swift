import XCTest
@testable import CabalmailKit

final class MessageSourceTests: XCTestCase {
    func testSplitOnCRLFCRLF() {
        let raw = "From: a@x.com\r\nSubject: hi\r\n\r\nHello, world.\r\n"
        let (headers, body) = MessageSource.split(raw)
        XCTAssertEqual(headers, "From: a@x.com\r\nSubject: hi")
        XCTAssertEqual(body, "Hello, world.\r\n")
    }

    func testSplitOnLFLFFallback() {
        let raw = "From: a@x.com\nSubject: hi\n\nHello, world.\n"
        let (headers, body) = MessageSource.split(raw)
        XCTAssertEqual(headers, "From: a@x.com\nSubject: hi")
        XCTAssertEqual(body, "Hello, world.\n")
    }

    func testSplitPrefersEarlierSeparator() {
        // A stray bare-LF blank line earlier than the CRLF CRLF should win,
        // because that's the first blank line the body actually starts after.
        // (RFC 5322 strict messages won't produce this, but real mail does.)
        let raw = "Header: one\n\nstart of body\r\n\r\nmore body"
        let (headers, body) = MessageSource.split(raw)
        XCTAssertEqual(headers, "Header: one")
        XCTAssertTrue(body.hasPrefix("start of body"))
    }

    func testSplitOnMissingSeparator() {
        let raw = "From: a@x.com\r\nSubject: hi (truncated"
        let (headers, body) = MessageSource.split(raw)
        XCTAssertEqual(headers, raw)
        XCTAssertEqual(body, "")
    }

    func testSplitEmptyInput() {
        let (headers, body) = MessageSource.split("")
        XCTAssertEqual(headers, "")
        XCTAssertEqual(body, "")
    }

    func testDecodeUTF8() {
        let raw = Data("Subject: café\r\n\r\nbody".utf8)
        XCTAssertEqual(MessageSource.decode(raw), "Subject: café\r\n\r\nbody")
    }

    func testDecodeFallsBackToLatin1() {
        // 0xE9 alone is invalid UTF-8 but a valid Latin-1 "é".
        var bytes = Data("Subject: ".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: "\r\n\r\nbody".utf8)
        let decoded = MessageSource.decode(bytes)
        XCTAssertTrue(decoded.contains("é"))
        XCTAssertTrue(decoded.hasSuffix("body"))
    }
}
