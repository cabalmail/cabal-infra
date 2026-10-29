import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The images a composer shows inline, and which of them go on the wire.
final class ComposeInlineImagesTests: XCTestCase {
    private static let jpeg = InlineImageEncoding.Encoded(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), format: .jpeg)

    func testAnAddedImageGetsAnIdTheHeaderCarriesAsWritten() {
        var images = ComposeInlineImages()

        let contentID = images.add(Self.jpeg)

        XCTAssertTrue(contentID.hasSuffix("@cabalmail"))
        XCTAssertLessThanOrEqual(contentID.count, 75, "the Lambda attaches an id it can't write literally")
        let image = try? XCTUnwrap(images.image(for: contentID))
        XCTAssertEqual(image?.mimeType, "image/jpeg")
        XCTAssertTrue(image?.filename.hasPrefix("image-") == true)
        XCTAssertTrue(image?.filename.hasSuffix(".jpg") == true)
        XCTAssertNotEqual(images.add(Self.jpeg), contentID)
    }

    func testOnlyTheImagesTheHTMLShowsGoOnTheWire() {
        var images = ComposeInlineImages()
        let shown = images.add(Self.jpeg)
        let deleted = images.add(Self.jpeg)
        let html = #"<p>Look</p><p><img src="cid:\#(shown)" alt="photo"></p><p>cid:\#(deleted)</p>"#

        let wire = images.attachments(shownIn: html)

        XCTAssertEqual(wire.compactMap(\.contentID), [shown], "text naming an image shows nothing")
        XCTAssertNotNil(images.image(for: deleted), "kept, so undo can bring it back")
        XCTAssertEqual(images.byteCount, 8)
    }

    func testAReferenceMayBeSingleQuotedOrInUpperCase() {
        XCTAssertTrue(ComposeInlineImages.html("<IMG SRC = 'CID:a@x'>", shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.html(#"<img src="cid:a@xy">"#, shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.html(#"<img src="cid:a.x">"#, shows: "a+x"), "the id is matched literally")
    }

    func testAQuotedMessagesInlineImageIsAdoptedUnderItsOwnID() {
        var images = ComposeInlineImages()
        let inline = Attachment(filename: "logo.png", mimeType: "image/png", data: Data([1]), contentID: "logo@x")
        let pdf = Attachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([2]), contentID: "doc@x")
        let plain = Attachment(filename: "b.png", mimeType: "image/png", data: Data([3]))

        XCTAssertTrue(images.adopt(inline))
        XCTAssertTrue(images.adopt(inline), "adopting it twice keeps one copy")
        XCTAssertFalse(images.adopt(pdf))
        XCTAssertFalse(images.adopt(plain))

        XCTAssertEqual(images.images.map(\.contentID), ["logo@x"])
        XCTAssertEqual(images.attachments(shownIn: #"<img src="cid:logo@x">"#).map(\.filename), ["logo.png"])
    }

    @MainActor
    func testAForwardsInlineImagesAreKeptApartFromItsAttachments() throws {
        let model = try TestFixtures.makeComposeModel()

        model.seedForwardedAttachments([
            Attachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1])),
            Attachment(filename: "logo.png", mimeType: "image/png", data: Data([2]), contentID: "logo@x"),
        ])

        XCTAssertEqual(model.attachments.map(\.filename), ["a.pdf"])
        XCTAssertEqual(model.inlineImages.images.map(\.contentID), ["logo@x"])
        XCTAssertEqual(model.attachmentTotalBytes, 2)
    }
}
