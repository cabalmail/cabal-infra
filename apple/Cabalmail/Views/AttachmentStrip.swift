import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
import QuickLook
#endif

/// Horizontal strip of attachment chips under the message body.
///
/// Tapping a chip opens the file in the platform's preview UI — on iOS /
/// visionOS via `QLPreviewController`, on macOS via `NSWorkspace.open(_:)`.
/// Phase 7 polish will replace the macOS path with
/// `NSSharingServicePicker` so the user can forward / save from the chip
/// directly.
struct AttachmentStrip: View {
    let attachments: [MessageDetailViewModel.Attachment]
    @State private var previewURL: URL?

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
                }
            }
            .padding(.horizontal)
        }
        #if os(iOS) || os(visionOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private func open(_ attachment: MessageDetailViewModel.Attachment) {
        #if os(macOS)
        NSWorkspace.shared.open(attachment.fileURL)
        #else
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
