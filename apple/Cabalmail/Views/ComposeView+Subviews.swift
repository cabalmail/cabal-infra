import SwiftUI
import CabalmailKit
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
            .foregroundStyle(.orange)
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
}
