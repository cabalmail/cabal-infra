import XCTest
import CabalmailKit
@testable import Cabalmail

/// What the reader takes as the message body and where it writes attachment
/// files, for workstream 0.8. Two fixes are protected here:
///
/// - #1812: a part marked `Content-Disposition: attachment` is never the body,
///   so a `.txt` or `.html` attachment is not shown as the message, quoted in
///   replies or donated to Spotlight.
/// - #1813: each reader writes attachments to its own temp folder, under
///   names unique within the message, so same-UID messages in two folders and
///   two same-named attachments in one message keep their own files.
@MainActor
final class MessageDetailAttachmentTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func snapshottedReader(imap: FakeImapClient, uid: UInt32) async throws -> MessageDetailViewModel {
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.seedSnapshot(model)
        return model
    }

    /// A `.txt` attachment is listed as an attachment and is not the body's
    /// plain text, so it is not what the plain-text view shows, what a reply
    /// quotes or what the reader donates to Spotlight. Before the #1812 fix the
    /// first `text/plain` part in the tree won whatever its disposition.
    func testATextAttachmentIsNotThePlainTextBody() async throws {
        let uid: UInt32 = 4_294_960_012
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.htmlWithTextAttachment)])
        let model = try await snapshottedReader(imap: imap, uid: uid)

        await model.load()

        XCTAssertEqual(model.htmlBody, "<p>Body</p>")
        XCTAssertNil(model.plainText)
        XCTAssertEqual(model.attachments.map(\.filename), ["notes.txt"])
    }

    /// The HTML twin of the case above (#1812): a plain message with an
    /// `.html` attachment shows its own text, not the attachment.
    func testAnHtmlAttachmentIsNotTheHtmlBody() async throws {
        let uid: UInt32 = 4_294_960_014
        let imap = FakeImapClient()
        let message = MessageDetailMimeFixture.message([
            "Subject: Page attached",
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
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(message)])
        let model = try await snapshottedReader(imap: imap, uid: uid)

        await model.load()

        XCTAssertNil(model.htmlBody)
        XCTAssertEqual(model.plainText, "See the page.")
        XCTAssertEqual(model.attachments.map(\.filename), ["page.html"])
    }

    /// Messages with the same UID in two folders keep their own attachment
    /// files: each reader writes to its own folder. Before the #1813 fix the
    /// folder was keyed by UID alone, so the later open overwrote what the
    /// earlier reader's attachment strip, and Forward, pointed at.
    func testSameUidMessagesInTwoFoldersKeepTheirOwnAttachmentFiles() async throws {
        let uid: UInt32 = 4_294_960_013
        let imap = FakeImapClient()
        let inboxBytes = MessageDetailMimeFixture.namedBlob("inbox copy")
        let archiveBytes = MessageDetailMimeFixture.namedBlob("archive copy")
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(inboxBytes)])
        await imap.scriptBody(folder: "Archive", uid: uid, [.success(archiveBytes)])
        let inbox = try await snapshottedReader(imap: imap, uid: uid)
        let archive = try await fixture.makeReader(imap: imap, uid: uid, folderPath: "Archive")
        try await fixture.seedSnapshot(archive)

        await inbox.load()
        await archive.load()

        let inboxFile = try XCTUnwrap(inbox.attachments.first?.fileURL)
        let archiveFile = try XCTUnwrap(archive.attachments.first?.fileURL)
        XCTAssertNotEqual(inboxFile, archiveFile)
        XCTAssertEqual(try Data(contentsOf: inboxFile), Data("inbox copy".utf8))
        XCTAssertEqual(try Data(contentsOf: archiveFile), Data("archive copy".utf8))
    }

    /// Two attachments with one name are two entries with two files (#1813).
    /// Before, both wrote one file, so the strip held one id for two entries
    /// and both pointed at the second attachment's bytes.
    func testTwoAttachmentsWithOneNameKeepTwoFiles() async throws {
        let uid: UInt32 = 4_294_960_015
        let imap = FakeImapClient()
        let message = MessageDetailMimeFixture.message([
            "Subject: Two scans",
            "Content-Type: multipart/mixed; boundary=\"mix\"",
            "",
            "--mix",
            "Content-Type: text/plain",
            "",
            "Two scans.",
            "--mix",
            "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"scan.bin\"",
            "",
            "first scan",
            "--mix",
            "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"SCAN.bin\"",
            "",
            "second scan",
            "--mix--",
            "",
        ])
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(message), .success(message)])
        let model = try await snapshottedReader(imap: imap, uid: uid)

        await model.load()

        XCTAssertEqual(model.attachments.map(\.filename), ["scan.bin", "SCAN.bin"])
        XCTAssertEqual(model.attachments.map(\.fileURL.lastPathComponent), ["scan.bin", "SCAN 2.bin"])
        XCTAssertEqual(Set(model.attachments.map(\.id)).count, 2)
        let contents = try model.attachments.map { try Data(contentsOf: $0.fileURL) }
        XCTAssertEqual(contents, [Data("first scan".utf8), Data("second scan".utf8)])

        // Loading again (Retry) rewrites the same two files rather than
        // numbering a third.
        let firstURLs = model.attachments.map(\.fileURL)
        try await model.client.bodyCache.invalidate(folder: "INBOX")
        await model.load()
        XCTAssertEqual(model.attachments.map(\.fileURL), firstURLs)
    }
}
