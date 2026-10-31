import XCTest
@testable import CabalmailUI

/// The symbol an attachment shows (`AttachmentIcon`), which its chip and the
/// Message menu's Attachments row share.
final class AttachmentIconTests: XCTestCase {
    private func icon(_ filename: String, _ mimeType: String) -> String {
        AttachmentIcon.systemImage(for: MessageDetailViewModel.Attachment(
            id: filename,
            filename: filename,
            mimeType: mimeType,
            size: 1,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename)")
        ))
    }

    func testAnInvitationShowsACalendarByTypeOrName() {
        XCTAssertEqual(icon("invite.ics", "text/calendar"), "calendar")
        XCTAssertEqual(icon("invite.ics", "application/octet-stream"), "calendar")
    }

    func testOtherFilesShowTheirKind() {
        XCTAssertEqual(icon("photo.jpg", "image/jpeg"), "photo")
        XCTAssertEqual(icon("memo.m4a", "audio/mp4"), "waveform")
        XCTAssertEqual(icon("clip.mov", "video/quicktime"), "film")
        XCTAssertEqual(icon("notes.txt", "text/plain"), "doc.text")
        XCTAssertEqual(icon("report.pdf", "application/pdf"), "paperclip")
    }
}
