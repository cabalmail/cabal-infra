import XCTest
import UniformTypeIdentifiers
import CabalmailKit
@testable import CabalmailUI

/// What a composer reads from an item dropped onto it, the name it gives the
/// attachment, and the type the attachment travels under.
final class DroppedAttachmentTests: XCTestCase {
    func testAMessageFromAListArrivesAsItsEml() {
        let type = DroppedAttachment.readableType(
            registered: [UTType.cabalmailMessageMove.identifier, UTType.emailMessage.identifier],
            hasSuggestedName: true
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

    func testTheSuggestedNameGainsTheTypesExtension() {
        let name = DroppedAttachment.filename(suggested:type:received:)
        XCTAssertEqual(name("IMG_0001", .png, "x.tmp"), "IMG_0001.png")
        XCTAssertEqual(name("Invoice.pdf", .pdf, "x.tmp"), "Invoice.pdf")
        XCTAssertEqual(name(nil, .pdf, "report.pdf"), "report.pdf")
    }

    func testAnImageIsTypedByItsBytesNotItsName() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

        XCTAssertEqual(DroppedAttachment.mimeType(forFilename: "photo.jpg", data: png), "image/png")
    }

    func testAFileIsTypedByItsExtensionAndAnUnknownOneAsOctetStream() {
        let mime = DroppedAttachment.mimeType(forFilename:data:)
        XCTAssertEqual(mime("Invoice.pdf", Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(mime("blob", Data([1, 2, 3])), "application/octet-stream")
    }
}
