import XCTest
@testable import CabalmailKit

final class MimeAttachmentPlanTests: XCTestCase {
    // Regression: an image attachment that also carries a Content-ID (Gmail
    // stamps one on every attached image) must still appear in the attachment
    // list. Keying "inline" purely off Content-ID hid it from the strip on the
    // Apple clients while the web client listed it fine.
    func testAttachmentDispositionImageWithContentIDIsListed() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let boundary = "BOUND"
        let message = """
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain; charset=us-ascii\r
        \r
        Body text.\r
        --\(boundary)\r
        Content-Type: image/jpeg; name="photo.jpg"\r
        Content-Disposition: attachment; filename="photo.jpg"\r
        Content-ID: <abc123>\r
        Content-Transfer-Encoding: base64\r
        \r
        \(jpeg.base64EncodedString())\r
        --\(boundary)--\r
        """
        let plan = MimeParser.parse(Data(message.utf8)).attachmentPlan()

        XCTAssertEqual(plan.attachments.count, 1)
        let attachment = plan.attachments.first
        XCTAssertEqual(attachment?.filename, "photo.jpg")
        XCTAssertEqual(attachment?.mimeType, "image/jpeg")
        XCTAssertEqual(attachment?.contentID, "abc123")
        XCTAssertEqual(attachment?.data, jpeg)
        // Also registered as inline so a `cid:` ref in the body still resolves.
        XCTAssertNotNil(plan.inlineImages["abc123"])
    }

    // A genuine inline image (image/* with a Content-ID and no attachment
    // disposition) resolves as inline and is NOT listed as an attachment.
    func testInlineImageWithoutAttachmentDispositionIsNotListed() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let boundary = "BOUND"
        let message = """
        Content-Type: multipart/related; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <img src="cid:logo">\r
        --\(boundary)\r
        Content-Type: image/png\r
        Content-Disposition: inline\r
        Content-ID: <logo>\r
        Content-Transfer-Encoding: base64\r
        \r
        \(png.base64EncodedString())\r
        --\(boundary)--\r
        """
        let plan = MimeParser.parse(Data(message.utf8)).attachmentPlan()

        XCTAssertTrue(plan.attachments.isEmpty)
        XCTAssertNotNil(plan.inlineImages["logo"])
    }

    // A non-image attachment (no Content-ID) is listed, using the
    // Content-Type name when Content-Disposition omits the filename.
    func testNonImageAttachmentIsListed() {
        let pdf = Data("%PDF-1.4".utf8)
        let boundary = "BOUND"
        let message = """
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain\r
        \r
        See attached.\r
        --\(boundary)\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pdf.base64EncodedString())\r
        --\(boundary)--\r
        """
        let plan = MimeParser.parse(Data(message.utf8)).attachmentPlan()

        XCTAssertEqual(plan.attachments.count, 1)
        XCTAssertEqual(plan.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(plan.attachments.first?.mimeType, "application/pdf")
        XCTAssertNil(plan.attachments.first?.contentID)
        XCTAssertTrue(plan.inlineImages.isEmpty)
    }

    // The rendered text/plain and text/html body alternatives are never
    // classified as attachments.
    func testBodyAlternativesAreNotAttachments() {
        let boundary = "BOUND"
        let message = """
        Content-Type: multipart/alternative; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain.\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML.</p>\r
        --\(boundary)--\r
        """
        let plan = MimeParser.parse(Data(message.utf8)).attachmentPlan()

        XCTAssertTrue(plan.attachments.isEmpty)
        XCTAssertTrue(plan.inlineImages.isEmpty)
    }
}
