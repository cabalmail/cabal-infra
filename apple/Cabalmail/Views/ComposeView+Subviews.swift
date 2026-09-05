import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

/// Stateless subview builders + the file-import attachment ingest path
/// split out of `ComposeView` to keep the struct body under the SwiftLint
/// length ceiling. Anything that touches `@State private` storage stays in
/// the main file because Swift's `private` is file-scoped — extensions in
/// other files can't see it.
extension ComposeView {
    @ViewBuilder
    func attachmentRow(_ attachment: ComposeViewModel.ComposeAttachment) -> some View {
        HStack {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(attachment.filename)
                    .font(.subheadline)
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(attachment.data.count),
                    countStyle: .file
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Byte-total warning shown under the attachment rows once the
    /// total crosses the model's warning threshold. Shared by the
    /// grouped-Form path (iOS et al.) and the macOS bottom strip.
    ///
    /// `AttachmentWarningTint` owns the colour and records why a plain
    /// `.orange` didn't clear the contrast floors in the light appearance
    /// (#1453).
    @ViewBuilder
    var attachmentSizeWarning: some View {
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(model.attachmentTotalBytes),
            countStyle: .file
        )
        let warning = "Attachments total \(total). Many mail servers reject "
            + "messages over 25 MB; delivery may fail."
        Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(AttachmentWarningTint.tint(for: colorScheme).color)
    }

    func ingestFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                model.addAttachment(
                    filename: url.lastPathComponent,
                    mimeType: mimeType(for: url),
                    data: data
                )
            }
        case .failure(let error):
            model.errorMessage = "Couldn't attach file: \(error.localizedDescription)"
        }
    }

    func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    #if os(iOS) || os(visionOS)
    /// `(mimeType, filenameExtension)` for an asset picked out of Photos.
    /// The bytes decide, because the bytes are what goes on the wire; the
    /// picker's own declared type is the fallback for a format
    /// `ImageDataFormat` does not know, and `application/octet-stream` the
    /// fallback for that (#1140).
    func photoTypeLabels(
        for item: PhotosPickerItem,
        data: Data
    ) -> (mime: String, ext: String) {
        if let format = ImageDataFormat.detect(data) {
            return (format.mimeType, format.filenameExtension)
        }
        if let declared = item.supportedContentTypes.first,
           let mime = declared.preferredMIMEType,
           let ext = declared.preferredFilenameExtension {
            return (mime, ext)
        }
        return ("application/octet-stream", "dat")
    }
    #endif
}
