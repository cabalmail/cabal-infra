import XCTest
@testable import CabalmailKit

final class MimeParserTests: XCTestCase {
    func testParsesPlainTextMessage() {
        let message = """
        From: alice@example.com\r
        To: bob@example.com\r
        Subject: Hello\r
        Content-Type: text/plain; charset=us-ascii\r
        \r
        Hello, world!
        """
        let part = MimeParser.parse(Data(message.utf8))
        XCTAssertEqual(part.contentType.mimeType, "text/plain")
        XCTAssertEqual(part.contentType.charset, "us-ascii")
        XCTAssertEqual(part.textContent(), "Hello, world!")
        XCTAssertTrue(part.children.isEmpty)
    }

    func testDecodesBase64Body() {
        let base64 = Data("Hello".utf8).base64EncodedString()
        let message = """
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(base64)
        """
        let part = MimeParser.parse(Data(message.utf8))
        XCTAssertEqual(part.encoding, .base64)
        XCTAssertEqual(part.textContent(), "Hello")
    }

    func testDecodesQuotedPrintableBodyWithSoftBreaksAndHexEscapes() {
        let message = """
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Hello=20world=\r
        , this =3D quoted printable
        """
        let part = MimeParser.parse(Data(message.utf8))
        XCTAssertEqual(part.textContent(), "Hello world, this = quoted printable")
    }

    func testParsesMultipartAlternativeTree() {
        let boundary = "xyz"
        let message = """
        Content-Type: multipart/alternative; boundary="\(boundary)"\r
        \r
        This is the preamble — ignore.\r
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain body\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML body</p>\r
        --\(boundary)--\r
        Epilogue — ignore.
        """
        let part = MimeParser.parse(Data(message.utf8))
        XCTAssertTrue(part.contentType.isMultipart)
        XCTAssertEqual(part.children.count, 2)
        let plain = part.firstPart { $0.contentType.mimeType == "text/plain" }
        let html = part.firstPart { $0.contentType.mimeType == "text/html" }
        XCTAssertEqual(plain?.textContent(), "Plain body")
        XCTAssertEqual(html?.textContent(), "<p>HTML body</p>")
    }

    func testMultipartMixedSurfacesAttachmentLeaves() {
        let boundary = "bnd"
        let base64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()  // PNG magic
        let message = """
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain\r
        \r
        Hi\r
        --\(boundary)\r
        Content-Type: image/png; name="pic.png"\r
        Content-Disposition: attachment; filename="pic.png"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(base64)\r
        --\(boundary)--
        """
        let part = MimeParser.parse(Data(message.utf8))
        let leaves = part.leafParts
        XCTAssertEqual(leaves.count, 2)
        let attachment = leaves.first { $0.contentDisposition?.isAttachment == true }
        XCTAssertEqual(attachment?.contentDisposition?.filename, "pic.png")
        XCTAssertEqual(attachment?.decodedBody, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testHeaderDecoderHandlesEncodedSubjectWords() {
        let subject = "=?utf-8?B?SGVsbG8gV29ybGQ=?="
        let decoded = HeaderDecoder.decode(subject)
        XCTAssertEqual(decoded, "Hello World")
    }

    func testHeaderDecoderHandlesMixedEncodingInSingleLine() {
        // `=_` is Q-encoding for underscore; space is bare.
        let value = "=?utf-8?Q?Hello=20=E2=98=83?= unencoded =?utf-8?B?V29ybGQ=?="
        let decoded = HeaderDecoder.decode(value)
        XCTAssertEqual(decoded, "Hello ☃ unencoded World")
    }

    func testHeaderDecoderDropsWhitespaceBetweenAdjacentEncodedWords() {
        let value = "=?utf-8?Q?Hello?= =?utf-8?Q?World?="
        let decoded = HeaderDecoder.decode(value)
        XCTAssertEqual(decoded, "HelloWorld")
    }

    func testMultipartWithEmptyLeadingSubPartDoesNotCrash() {
        // Regression: Microsoft-originated DMARC aggregate reports wrap their
        // body in multipart/mixed → multipart/related → multipart/alternative,
        // and the alternative's first sub-part is empty (no headers, no body).
        // After boundary trimming an empty `Data` reaches the recursive
        // `parse(_:)`, which previously trapped in `findBlankLine` on
        // `0..<(0 - 1)`.
        let outer = "mpm"
        let related = "rv"
        let alternative = "av"
        let message = """
        Content-Type: multipart/mixed; boundary="\(outer)"\r
        \r
        --\(outer)\r
        Content-Type: multipart/related; boundary="\(related)"\r
        \r
        --\(related)\r
        Content-Type: multipart/alternative; boundary="\(alternative)"\r
        \r
        --\(alternative)\r
        \r
        --\(alternative)\r
        Content-Type: text/html; charset=us-ascii\r
        \r
        <p>body</p>\r
        --\(alternative)--\r
        --\(related)--\r
        --\(outer)\r
        Content-Type: application/gzip\r
        Content-Disposition: attachment; filename="report.xml.gz"\r
        Content-Transfer-Encoding: base64\r
        \r
        H4sIAAAAAAAAAA==\r
        --\(outer)--
        """
        let part = MimeParser.parse(Data(message.utf8))
        XCTAssertTrue(part.contentType.isMultipart)
        let html = part.firstPart { $0.contentType.mimeType == "text/html" }
        XCTAssertEqual(html?.textContent(), "<p>body</p>")
        let attachment = part.leafParts.first { $0.contentDisposition?.isAttachment == true }
        XCTAssertEqual(attachment?.contentDisposition?.filename, "report.xml.gz")
    }

    func testCidInlineImageInNestedRelatedIsExtractable() {
        // Mirrors a USPS Informed Delivery digest: multipart/alternative whose
        // HTML alternative is itself a multipart/related carrying the inline
        // mailpiece images by Content-ID. The HTML references them as
        // `cid:1005412273-018.jpg` (quoted-printable encoded on the wire).
        let outer = "OUTER"
        let related = "INNER"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()  // JPEG magic
        let message = """
        Content-Type: multipart/alternative; boundary="\(outer)"\r
        \r
        --\(outer)\r
        Content-Type: text/plain; charset="UTF-8"\r
        \r
        Plain digest\r
        --\(outer)\r
        Content-Type: multipart/related; boundary="\(related)"\r
        \r
        --\(related)\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <img src=3D"cid:1005412273-018.jpg" alt=3D"Mailpiece Image">\r
        --\(related)\r
        Content-Type: image/jpeg\r
        Content-Transfer-Encoding: base64\r
        Content-ID: <1005412273-018.jpg>\r
        Content-Disposition: inline; filename="1005412273-018.jpg"\r
        \r
        \(jpeg)\r
        --\(related)--\r
        --\(outer)--
        """
        let part = MimeParser.parse(Data(message.utf8))

        // The HTML, once transfer-decoded, references the cid.
        let html = part.firstPart { $0.contentType.mimeType == "text/html" }
        XCTAssertEqual(
            html?.textContent(),
            #"<img src="cid:1005412273-018.jpg" alt="Mailpiece Image">"#
        )

        // The image leaf must surface with its angle-bracket-stripped
        // Content-ID so the view's cid→data rewrite can match the `src`.
        let image = part.leafParts.first { $0.contentType.type == "image" }
        XCTAssertNotNil(image, "inline image part should be a leaf")
        XCTAssertEqual(image?.contentID, "1005412273-018.jpg")
        XCTAssertEqual(image?.decodedBody, Data([0xFF, 0xD8, 0xFF, 0xE0]))

        // It exposes a `data:` URI (not a file URL) so the WKWebView, whose
        // opaque origin can't load file:// subresources, can render it.
        let expectedBase64 = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        XCTAssertEqual(
            image?.inlineImageDataURL?.absoluteString,
            "data:image/jpeg;base64,\(expectedBase64)"
        )
    }

    func testInlineImageDataURLNilForNonImageOrMissingContentID() {
        // A part with a Content-ID but a non-image type → not inline.
        let textWithCID = MimeParser.parse(Data("""
        Content-Type: text/calendar\r
        Content-ID: <evt@x>\r
        \r
        BEGIN:VCALENDAR
        """.utf8))
        XCTAssertNil(textWithCID.inlineImageDataURL)

        // An image with no Content-ID → a regular attachment, not inline.
        let imageNoCID = MimeParser.parse(Data("""
        Content-Type: image/png\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        """.utf8))
        XCTAssertNil(imageNoCID.inlineImageDataURL)
    }

    func testFoldedHeadersUnfoldIntoSingleValue() {
        let message = """
        Subject: Hello\r
         world\r
        Content-Type: text/plain\r
        \r
        body
        """
        let part = MimeParser.parse(Data(message.utf8))
        let subject = part.headers.first { $0.name == "Subject" }?.value
        XCTAssertEqual(subject, "Hello world")
    }
}
