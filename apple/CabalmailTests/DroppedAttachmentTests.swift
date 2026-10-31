import XCTest
import UniformTypeIdentifiers
import CabalmailKit
@testable import CabalmailUI

/// What a composer reads from an item dropped onto it, the name it gives the
/// attachment, and the type the attachment travels under.
final class DroppedAttachmentTests: XCTestCase {
    func testAMessageFromAListArrivesAsItsEml() {
        let type = DroppedAttachment.readableType(
            registered: [UTType.emlFile.identifier, UTType.cabalmailMessageMove.identifier],
            hasSuggestedName: true
        )

        XCTAssertEqual(type, .emlFile)
    }

    func testAMessageFromAnotherAppIsReadAsAMessage() {
        let type = DroppedAttachment.readableType(
            registered: [UTType.utf8PlainText.identifier, UTType.emailMessage.identifier],
            hasSuggestedName: false
        )

        XCTAssertEqual(type, .emailMessage)
    }

    func testAMoveReferenceAloneIsLeft() {
        // What a drag of several messages carries: no `.eml`.
        XCTAssertNil(DroppedAttachment.readableType(
            registered: [UTType.cabalmailMessageMove.identifier],
            hasSuggestedName: false
        ))
    }

    func testAMoveReferenceTheEditorReadIsLeft() throws {
        // The editor page reads whatever a drag offers as a file, the move
        // reference of a several-message drag included.
        let two = [MessageDragItem(uid: 1, sourceFolder: "INBOX"), MessageDragItem(uid: 2, sourceFolder: "INBOX")]
        let reference = try JSONEncoder().encode(MessageDragPayload(items: two))

        XCTAssertTrue(DroppedAttachment.isMoveReference(reference))
        XCTAssertFalse(DroppedAttachment.isMoveReference(Data("From: a@b\r\n\r\nhi".utf8)))
        XCTAssertFalse(DroppedAttachment.isMoveReference(Data(#"{"items": "a list"}"#.utf8)))
        XCTAssertFalse(DroppedAttachment.isMoveReference(Data(#"{"items": []}"#.utf8)), "a JSON file, not a drag")
    }

    func testAFileIsReadAsItsOwnType() {
        XCTAssertEqual(
            DroppedAttachment.readableType(registered: [UTType.pdf.identifier], hasSuggestedName: true),
            .pdf
        )
    }

    func testATextSelectionIsLeftButATextFileIsRead() {
        let text = [UTType.utf8PlainText.identifier]

        XCTAssertNil(DroppedAttachment.readableType(registered: text, hasSuggestedName: false))
        XCTAssertEqual(DroppedAttachment.readableType(registered: text, hasSuggestedName: true), .utf8PlainText)
    }

    func testALinkOrRichSelectionIsLeftButAnImageWithALinkIsRead() {
        let readable = DroppedAttachment.readableType(registered:hasSuggestedName:)
        XCTAssertNil(readable([UTType.url.identifier, UTType.utf8PlainText.identifier], false))
        XCTAssertNil(readable(["com.apple.webarchive", UTType.html.identifier, UTType.utf8PlainText.identifier], false))
        XCTAssertEqual(readable([UTType.png.identifier, UTType.url.identifier], false), .png)
    }

    func testTheSuggestedNameGainsTheTypesExtension() {
        let name = DroppedAttachment.filename(suggested:type:received:)
        XCTAssertEqual(name("IMG_0001", .png, "x.tmp"), "IMG_0001.png")
        XCTAssertEqual(name("Invoice.pdf", .pdf, "x.tmp"), "Invoice.pdf")
        XCTAssertEqual(name(nil, .pdf, "report.pdf"), "report.pdf")
        XCTAssertEqual(name("Report v1.2", .pdf, "x.tmp"), "Report v1.2.pdf", "a dot in the name is not an extension")
    }

    func testAnImageIsTypedByItsBytesNotItsName() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

        XCTAssertEqual(DroppedAttachment.mimeType(forFilename: "photo.jpg", data: png), "image/png")
    }

    func testAFileIsTypedByItsExtensionAndAnUnknownOneAsOctetStream() {
        let mime = DroppedAttachment.mimeType(forFilename:data:)
        XCTAssertEqual(mime("Invoice.pdf", Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(mime("blob", Data([1, 2, 3])), "application/octet-stream")
        XCTAssertEqual(mime("Notification test.eml", Data("From: a@b\r\n\r\nhi".utf8)), "application/octet-stream",
                       "the send path base64-encodes parts, which a message/rfc822 part may not be")
    }
}
