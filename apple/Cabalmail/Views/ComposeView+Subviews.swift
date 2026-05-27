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
    func recipientField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, axis: .vertical)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
    }

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
