import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Files dropped or pasted onto the Rich Text body, as the composer takes
/// them from its editor (`DroppedAttachment.takeEditorDrops`): images inline,
/// anything else attached.
@MainActor
final class EditorDroppedAttachmentTests: XCTestCase {
    private static let pdf = Data("%PDF-1.7".utf8)
    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    private func file(_ name: String, _ contents: EditorFileDrops.Contents, id: Int = 1) -> EditorFileDrops.File {
        EditorFileDrops.File(id: id, name: name, contents: contents)
    }

    func testSendWaitsForEveryFileThePageSaidWasComing() async throws {
        let model = try TestFixtures.makeComposeModel()
        let drops = model.editorController.fileDrops

        drops.onStarted?(2)
        XCTAssertEqual(model.pendingDrops, 2)

        drops.onFile?(file("Invoice.pdf", .data(Self.pdf)))
        try await waitUntilOnMainActor { model.pendingDrops == 1 }
        XCTAssertEqual(model.attachments.map(\.filename), ["Invoice.pdf"])
        XCTAssertEqual(model.attachments.first?.mimeType, "application/pdf")

        drops.onFile?(file("photo.heic", .unreadable, id: 2))
        try await waitUntilOnMainActor { model.pendingDrops == 0 }
        XCTAssertEqual(model.errorMessage, "Couldn't attach photo.heic.")
        XCTAssertEqual(model.attachments.count, 1)
    }

    func testAFileTooLargeToReadSaysSo() async throws {
        let model = try TestFixtures.makeComposeModel()

        await DroppedAttachment.take(file("film.mov", .tooLarge(limitBytes: 50_000_000)), into: model)

        XCTAssertEqual(model.errorMessage, "Couldn't attach film.mov: it's larger than 50 MB.")
        XCTAssertTrue(model.attachments.isEmpty)
    }

    func testSeveralMessagesAreLeftWithAWord() async throws {
        let model = try TestFixtures.makeComposeModel()
        let two = [MessageDragItem(uid: 1, sourceFolder: "INBOX"), MessageDragItem(uid: 2, sourceFolder: "INBOX")]
        let reference = try JSONEncoder().encode(MessageDragPayload(items: two))

        await DroppedAttachment.take(file("", .data(reference)), into: model)

        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(model.errorMessage, "To attach messages, drag them one at a time.")
    }

    func testAFileThatArrivesOnceTheComposerHasMovedIsLeft() async throws {
        let model = try TestFixtures.makeComposeModel()
        model.isMovingToWindow = true

        await DroppedAttachment.take(file("Invoice.pdf", .data(Self.pdf)), into: model)

        XCTAssertTrue(model.attachments.isEmpty)
    }

    /// An image the page has no place for (it wasn't dropped onto the page)
    /// is attached rather than lost.
    func testAnImageThePageCannotPlaceIsAttached() async throws {
        let model = try TestFixtures.makeComposeModel()
        try await TestFixtures.requireEditorBridge(model)

        await DroppedAttachment.take(file("photo.png", .data(Self.png), id: 999), into: model)

        XCTAssertEqual(model.attachments.map(\.filename), ["photo.png"])
        XCTAssertTrue(model.inlineImages.images.isEmpty)
    }

    /// An image dropped onto the page shows inline where it was dropped, and
    /// goes on the wire inline: carrying the Content-ID the sent HTML shows,
    /// and not in the attachment list.
    func testADroppedImageShowsInlineAndIsSentInline() async throws {
        let model = try TestFixtures.makeComposeModel()
        try await TestFixtures.requireEditorBridge(model)

        _ = try await model.editorController.webView.evaluateJavaScript("""
            (function (base64) {
              const editor = document.getElementById('editor');
              const data = new DataTransfer();
              const bytes = Uint8Array.from(atob(base64), function (c) { return c.charCodeAt(0); });
              data.items.add(new File([bytes], 'photo.png', { type: 'image/png' }));
              const event = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: data });
              if (event.dataTransfer !== data) Object.defineProperty(event, 'dataTransfer', { value: data });
              editor.dispatchEvent(event);
              return true;
            })('\(Self.png.base64EncodedString())')
            """)
        try await waitUntilOnMainActor { model.inlineImages.images.count == 1 && model.pendingDrops == 0 }

        let image = try XCTUnwrap(model.inlineImages.images.first)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertFalse(model.richMirrorsMarkdown, "the send path would read the untouched Markdown pane")
        let html = await model.editorController.getHTML()
        XCTAssertTrue(html.contains(#"src="cid:\#(image.contentID)""#), html)
        let from = try XCTUnwrap(EmailAddress(parsing: "daily@cabalmail.example"))
        let bodies = ComposeBodies(text: "", html: html, source: .rich)
        let outgoing = model.buildOutgoingMessage(from: from, bodies: bodies)
        XCTAssertEqual(outgoing.attachments.map(\.contentID), [image.contentID])
        XCTAssertEqual(outgoing.attachments.first?.data, Self.png)
    }
}
