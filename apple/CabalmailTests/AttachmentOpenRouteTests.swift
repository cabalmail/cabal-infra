import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Which attachments the reader opens as an invitation on iOS and visionOS
/// (`AttachmentOpenRoute`), the rule the chips used before it moved into
/// the reader's presenter: a calendar attachment with at least one event,
/// and nothing else.
final class AttachmentOpenRouteTests: XCTestCase {
    private let invite = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "METHOD:REQUEST",
        "BEGIN:VEVENT",
        "DTSTART:20261105T150000Z",
        "DTEND:20261105T160000Z",
        "UID:route-1@example.com",
        "SUMMARY:Planning",
        "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    private let noEvents = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    private func attachment(_ filename: String, mimeType: String) -> MessageDetailViewModel.Attachment {
        MessageDetailViewModel.Attachment(
            id: filename,
            filename: filename,
            mimeType: mimeType,
            size: 1,
            fileURL: URL(fileURLWithPath: "/tmp/\(filename)")
        )
    }

    func testAnInvitationWithAnEventOpensAsAnInvitation() throws {
        let calendar = try XCTUnwrap(
            AttachmentOpenRoute.invitation(in: attachment("invite.ics", mimeType: "text/calendar")) { _ in
                Data(self.invite.utf8)
            }
        )
        XCTAssertEqual(calendar.events.map(\.uid), ["route-1@example.com"])
    }

    /// Senders that ship an invitation as a generic binary still name it
    /// `.ics`.
    func testAnICSFileNamedSoIsAnInvitationWhateverItsType() {
        let route = AttachmentOpenRoute.invitation(
            in: attachment("invite.ics", mimeType: "application/octet-stream")
        ) { _ in Data(self.invite.utf8) }

        XCTAssertNotNil(route)
    }

    /// An invitation with nothing to add, or one that can't be read, is
    /// previewed like any other file.
    func testAnInvitationWithoutAnEventOrUnreadablePreviews() {
        let file = attachment("invite.ics", mimeType: "text/calendar")

        XCTAssertNil(AttachmentOpenRoute.invitation(in: file) { _ in Data(self.noEvents.utf8) })
        XCTAssertNil(AttachmentOpenRoute.invitation(in: file) { _ in nil })
        XCTAssertNil(AttachmentOpenRoute.invitation(in: file) { _ in Data("not a calendar".utf8) })
    }

    /// Any other file previews, and is never read to find out.
    func testAnyOtherFilePreviewsWithoutBeingRead() {
        var reads = 0
        let route = AttachmentOpenRoute.invitation(in: attachment("photo.jpg", mimeType: "image/jpeg")) { _ in
            reads += 1
            return Data(self.invite.utf8)
        }

        XCTAssertNil(route)
        XCTAssertEqual(reads, 0)
    }
}
