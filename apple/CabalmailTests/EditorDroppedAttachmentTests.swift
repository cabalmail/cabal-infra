import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Files dropped onto the Rich Text body, as the composer takes them from
/// its editor (`DroppedAttachment.takeEditorDrops`).
@MainActor
final class EditorDroppedAttachmentTests: XCTestCase {
    private static let pdf = Data("%PDF-1.7".utf8)

    func testSendWaitsForEveryFileThePageSaidWasComing() throws {
        let model = try TestFixtures.makeComposeModel()
        DroppedAttachment.takeEditorDrops(into: model)
        let editor = model.editorController

        editor.onDropStarted?(2)
        XCTAssertEqual(model.pendingDrops, 2)

        editor.onDroppedFile?("Invoice.pdf", .data(Self.pdf))
        XCTAssertEqual(model.pendingDrops, 1)
        XCTAssertEqual(model.attachments.map(\.filename), ["Invoice.pdf"])
        XCTAssertEqual(model.attachments.first?.mimeType, "application/pdf")

        editor.onDroppedFile?("photo.heic", .unreadable)
        XCTAssertEqual(model.pendingDrops, 0)
        XCTAssertEqual(model.errorMessage, "Couldn't attach photo.heic.")
        XCTAssertEqual(model.attachments.count, 1)
    }

    func testAFileTooLargeToReadSaysSo() throws {
        let model = try TestFixtures.makeComposeModel()

        DroppedAttachment.take(.tooLarge(limitBytes: 50_000_000), named: "film.mov", into: model)

        XCTAssertEqual(model.errorMessage, "Couldn't attach film.mov: it's larger than 50 MB.")
        XCTAssertTrue(model.attachments.isEmpty)
    }

    func testSeveralMessagesAreLeftWithAWord() throws {
        let model = try TestFixtures.makeComposeModel()
        let two = [MessageDragItem(uid: 1, sourceFolder: "INBOX"), MessageDragItem(uid: 2, sourceFolder: "INBOX")]
        let reference = try JSONEncoder().encode(MessageDragPayload(items: two))

        DroppedAttachment.take(.data(reference), named: "", into: model)

        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(model.errorMessage, "To attach messages, drag them one at a time.")
    }

    func testAFileThatArrivesOnceTheComposerHasMovedIsLeft() throws {
        let model = try TestFixtures.makeComposeModel()
        model.isMovingToWindow = true

        DroppedAttachment.take(.data(Self.pdf), named: "Invoice.pdf", into: model)

        XCTAssertTrue(model.attachments.isEmpty)
    }
}
