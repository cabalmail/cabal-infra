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
    }

    func testTheSizeCountsTheImagesTheBodyShowsSinceItsLastEdit() {
        var images = ComposeInlineImages()
        let kept = images.add(Self.jpeg)
        _ = images.add(Self.jpeg)
        XCTAssertEqual(images.byteCount, 8, "before an edit, every image held was just shown")

        images.shown = [kept]

        XCTAssertEqual(images.byteCount, 4, "a deleted image is no longer counted")
    }

    func testAReferenceMayBeSingleQuotedOrInUpperCase() {
        XCTAssertTrue(ComposeInlineImages.html("<IMG SRC = 'CID:a@x'>", shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.html(#"<img src="cid:a@xy">"#, shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.html(#"<img src="cid:a.x">"#, shows: "a+x"), "the id is matched literally")
    }

    func testAQuotedMessagesInlineImageIsAdoptedUnderItsOwnIDWhenTheBodyShowsIt() {
        var images = ComposeInlineImages()
        let body = "Look:\n\n![logo](cid:logo@x)\n\nFooter: [cid:other@x]"
        let inline = Attachment(filename: "logo.png", mimeType: "image/png", data: Data([1]), contentID: "logo@x")
        let unshown = Attachment(filename: "other.png", mimeType: "image/png", data: Data([4]), contentID: "other@x")
        let pdf = Attachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([2]), contentID: "doc@x")
        let plain = Attachment(filename: "b.png", mimeType: "image/png", data: Data([3]))

        XCTAssertTrue(images.adopt(inline, shownIn: body))
        XCTAssertTrue(images.adopt(inline, shownIn: body), "adopting it twice keeps one copy")
        XCTAssertTrue(images.adopt(unshown, shownIn: body), "an inline image the body doesn't show isn't attached")
        XCTAssertFalse(images.adopt(pdf, shownIn: body))
        XCTAssertFalse(images.adopt(plain, shownIn: body))

        XCTAssertEqual(images.images.map(\.contentID), ["logo@x"])
        XCTAssertEqual(images.attachments(shownIn: #"<img src="cid:logo@x">"#).map(\.filename), ["logo.png"])
    }

    func testMarkdownShowsAnImageOrRawHTMLThatNamesIt() {
        XCTAssertTrue(ComposeInlineImages.markdown("![a](cid:a@x)", shows: "a@x"))
        XCTAssertTrue(ComposeInlineImages.markdown(#"![a](cid:a@x "title")"#, shows: "a@x"))
        XCTAssertTrue(ComposeInlineImages.markdown(#"<img src="cid:a@x">"#, shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.markdown("[cid:a@x]", shows: "a@x"))
        XCTAssertFalse(ComposeInlineImages.markdown("![a](cid:a@xy)", shows: "a@x"))
    }

    @MainActor
    func testAForwardKeepsTheInlineImagesItsQuoteShowsApartFromItsAttachments() throws {
        let model = try TestFixtures.makeComposeModel(seed: Draft(body: "> Look:\n>\n> ![logo](cid:logo@x)"))

        model.seedForwardedAttachments([
            Attachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1])),
            Attachment(filename: "logo.png", mimeType: "image/png", data: Data([2]), contentID: "logo@x"),
            Attachment(filename: "photo.jpg", mimeType: "image/jpeg", data: Data(count: 30), contentID: "photo@x"),
        ])

        XCTAssertEqual(model.attachments.map(\.filename), ["a.pdf"])
        XCTAssertEqual(model.inlineImages.images.map(\.contentID), ["logo@x"])
        XCTAssertEqual(model.attachmentTotalBytes, 2, "an inline image the quote doesn't show isn't counted")
    }
}
