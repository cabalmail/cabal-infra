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
            Image(systemName: AttachmentIcon.systemImage(for: attachment))
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

    private func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The symbol an attachment shows, on its chip and in the Message menu's
/// Attachments submenu alike.
enum AttachmentIcon {
    static func systemImage(for attachment: MessageDetailViewModel.Attachment) -> String {
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
}

/// The Message menu's Attachments submenu: a row per attachment that opens
/// it as its chip does. A view of its own so that it reads
/// `\.openAttachment` inside the reader's presenter: the reader's own
/// environment comes from outside the `presentsAttachments()` it applies.
struct ReaderAttachmentsMenu: View {
    let attachments: [MessageDetailViewModel.Attachment]
    @Environment(\.openAttachment) private var openAttachment

    var body: some View {
        Menu {
            ForEach(attachments) { attachment in
                Button {
                    openAttachment?(attachment)
                } label: {
                    Label(attachment.filename, systemImage: AttachmentIcon.systemImage(for: attachment))
                }
            }
        } label: {
            Label("Attachments", systemImage: "paperclip")
        }
    }
}
