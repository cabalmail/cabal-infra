import SwiftUI
import CabalmailKit

/// Horizontal strip of attachment chips under the message header.
///
/// Tapping a chip opens the file through the reader's attachment presenter
/// (`\.openAttachment`, `presentsAttachments()`): Quick Look on iOS and
/// visionOS, with an invitation in `CalendarEventSheet`, and the system's
/// own handler on macOS. Phase 7 polish will replace the macOS path with
/// `NSSharingServicePicker` so the user can forward / save from the chip
/// directly.
struct AttachmentStrip: View {
    let attachments: [MessageDetailViewModel.Attachment]
    @Environment(\.openAttachment) private var openAttachment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    Button {
                        openAttachment?(attachment)
                    } label: {
                        AttachmentChip(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.attachment.\(attachment.filename)")
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct AttachmentChip: View {
    let attachment: MessageDetailViewModel.Attachment

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(formatSize(attachment.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var iconName: String {
        if ICalendar.isCalendarAttachment(mimeType: attachment.mimeType, filename: attachment.filename) {
            return "calendar"
        }
        switch attachment.mimeType.split(separator: "/").first?.lowercased() {
        case "image":  return "photo"
        case "audio":  return "waveform"
        case "video":  return "film"
        case "text":   return "doc.text"
        default:       return "paperclip"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
