import XCTest
@testable import CabalmailKit

/// `MimePart.bodyPart(mimeType:)` picks the message text the reader shows,
/// quotes in replies and indexes for Spotlight. A part the sender marked
/// `Content-Disposition: attachment` is an attachment, never the body
/// (#1812): before, the first `text/plain` or `text/html` part in the tree won
/// whatever its disposition, so an HTML message with `notes.txt` attached
/// showed the notes as its plain text, and a plain message with `page.html`
/// attached showed the attachment as the message.
final class MimeBodyPartTests: XCTestCase {
    private func parse(_ lines: [String]) -> MimePart {
        MimeParser.parse(Data(lines.joined(separator: "\r\n").utf8))
    }

    func testATextAttachmentIsNotThePlainBodyOfAnHtmlMessage() {
        let root = parse([
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>Body</p>",
            "--mix",
            "Content-Type: text/plain; name=\"notes.txt\"",
            "Content-Disposition: attachment; filename=\"notes.txt\"",
            "",
            "attached notes",
            "--mix--",
            "",
        ])

        XCTAssertNil(root.bodyPart(mimeType: "text/plain"))
        XCTAssertEqual(root.bodyPart(mimeType: "text/html")?.textContent(), "<p>Body</p>")
        XCTAssertEqual(root.attachmentPlan().attachments.map(\.filename), ["notes.txt"])
    }

    func testAnHtmlAttachmentIsNotTheHtmlBodyOfAPlainMessage() {
        let root = parse([
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "See the page.",
            "--mix",
            "Content-Type: text/html; name=\"page.html\"",
            "Content-Disposition: attachment; filename=\"page.html\"",
            "",
            "<h1>Attached page</h1>",
            "--mix--",
            "",
        ])

        XCTAssertNil(root.bodyPart(mimeType: "text/html"))
        XCTAssertEqual(root.bodyPart(mimeType: "text/plain")?.textContent(), "See the page.")
        XCTAssertEqual(root.attachmentPlan().attachments.map(\.filename), ["page.html"])
    }

    /// The attachment comes first in tree order here, so the old first-match
    /// rule took it over the real body.
    func testTheBodyIsFoundPastAnEarlierTextAttachment() {
        let root = parse([
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/plain; name=\"readme.txt\"",
            "Content-Disposition: attachment; filename=\"readme.txt\"",
            "",
            "attached readme",
            "--mix",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "The real body.",
            "--mix--",
            "",
        ])

        XCTAssertEqual(root.bodyPart(mimeType: "text/plain")?.textContent(), "The real body.")
    }

    func testBothAlternativesOfAnOrdinaryMessageAreFound() {
        let root = parse([
            "Content-Type: multipart/alternative; boundary=\"alt\"",
            "",
            "--alt",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Plain body.",
            "--alt",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>HTML body.</p>",
            "--alt--",
            "",
        ])

        XCTAssertEqual(root.bodyPart(mimeType: "text/plain")?.textContent(), "Plain body.")
        XCTAssertEqual(root.bodyPart(mimeType: "text/html")?.textContent(), "<p>HTML body.</p>")
    }

    /// An `inline` disposition, even with a file name, is still body text,
    /// as it is to `fetch_message`.
    func testAnInlineTextPartWithAFileNameIsStillTheBody() {
        let root = parse([
            "Content-Type: text/plain; charset=utf-8",
            "Content-Disposition: inline; filename=\"message.txt\"",
            "",
            "Inline body.",
            "",
        ])

        XCTAssertEqual(root.bodyPart(mimeType: "text/plain")?.textContent(), "Inline body.\r\n")
    }

    func testAMessageWhoseOnlyTextIsAnAttachmentHasNoBody() {
        let root = parse([
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/plain; name=\"only.txt\"",
            "Content-Disposition: attachment; filename=\"only.txt\"",
            "",
            "only attachment",
            "--mix--",
            "",
        ])

        XCTAssertNil(root.bodyPart(mimeType: "text/plain"))
        XCTAssertNil(root.bodyPart(mimeType: "text/html"))
        XCTAssertEqual(root.attachmentPlan().attachments.map(\.filename), ["only.txt"])
    }
}
