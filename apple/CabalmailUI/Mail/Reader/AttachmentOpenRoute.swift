import Foundation
import CabalmailKit

/// How the reader opens an attachment where Calendar can't take an `.ics`
/// itself (iOS and visionOS): an invitation with at least one event opens
/// in `CalendarEventSheet`, anything else in the platform's preview, an
/// invitation that doesn't parse included. macOS hands every file to the
/// system (`presentsAttachments()`).
enum AttachmentOpenRoute {
    /// The invitation `attachment` carries, read with `read`, or nil when
    /// it isn't a calendar attachment, can't be read, or holds no event.
    /// `read` runs only for a calendar attachment.
    static func invitation(
        in attachment: MessageDetailViewModel.Attachment,
        read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> ICalendar? {
        guard ICalendar.isCalendarAttachment(mimeType: attachment.mimeType, filename: attachment.filename),
              let data = read(attachment.fileURL),
              let calendar = ICalendarParser.parse(data),
              !calendar.events.isEmpty else {
            return nil
        }
        return calendar
    }
}
