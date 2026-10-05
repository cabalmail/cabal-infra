import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import UIKit
import QuickLook
#endif

/// Horizontal strip of attachment chips under the message body.
///
/// Tapping a chip opens the file in the platform's preview UI — on iOS /
/// visionOS via `QLPreviewController`, on macOS via `NSWorkspace.open(_:)`.
/// Calendar invites (`.ics`) are the exception on iOS / visionOS: QuickLook
/// can only display them and Calendar offers no share-sheet route, so they
/// open in `CalendarEventSheet` with an Add to Calendar flow instead (an
/// unparseable invite still falls back to QuickLook). On macOS the plain
/// `open` already lands in Calendar's own import prompt. Phase 7 polish
/// will replace the macOS path with `NSSharingServicePicker` so the user
/// can forward / save from the chip directly.
struct AttachmentStrip: View {
    let attachments: [MessageDetailViewModel.Attachment]
    @State private var previewURL: URL?
    #if canImport(EventKitUI)
    @State private var calendarInvite: CalendarInvite?
    #endif

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    Button {
                        open(attachment)
                    } label: {
                        AttachmentChip(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.attachment.\(attachment.filename)")
                }
            }
            .padding(.horizontal)
        }
        #if os(iOS) || os(visionOS)
        .quickLookPreview($previewURL)
        #endif
        #if canImport(EventKitUI)
        .sheet(item: $calendarInvite) { invite in
            CalendarEventSheet(invite: invite)
        }
        #endif
    }

    private func open(_ attachment: MessageDetailViewModel.Attachment) {
        #if os(macOS)
        NSWorkspace.shared.open(attachment.fileURL)
        #else
        #if canImport(EventKitUI)
        if ICalendar.isCalendarAttachment(mimeType: attachment.mimeType, filename: attachment.filename),
           let data = try? Data(contentsOf: attachment.fileURL),
           let calendar = ICalendarParser.parse(data),
           !calendar.events.isEmpty {
            calendarInvite = CalendarInvite(calendar: calendar)
            return
        }
        #endif
        previewURL = attachment.fileURL
        #endif
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
