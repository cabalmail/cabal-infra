import SwiftUI
import UniformTypeIdentifiers
import CabalmailKit

/// Files, images and messages dropped onto a composer become attachments:
/// from Files, Photos or another app beside Cabalmail in Split View (the
/// iPhone Duo spec), from a Cabalmail message list in another window (as an
/// `.eml`), or from the Finder into a Mac compose window. They take the same
/// path as the photo and file pickers, `ComposeViewModel.addAttachment`.
///
/// Read through `NSItemProvider` rather than a `Transferable` drop: a
/// `FileRepresentation` import never matched a drag whose types are only
/// registered as data, which is how a message list offers its `.eml`
/// (measured on the iPhone Duo simulator), and the provider also carries the
/// file name the sending app suggests.
enum DroppedAttachment {
    /// The type to read an item as, or nil to leave it: a message's `.eml`
    /// first, then the item's first data type, skipping a message list's
    /// move reference (it means nothing outside the list it came from) and
    /// text with no file name, which is a selection rather than a file.
    static func readableType(registered identifiers: [String], hasSuggestedName: Bool) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if let eml = types.first(where: { $0.conforms(to: .emailMessage) }) {
            return eml
        }
        return types.first { type in
            type.conforms(to: .data)
                && type != .cabalmailMessageMove
                && (hasSuggestedName || !type.conforms(to: .text))
        }
    }

    /// The attachment's file name: the one the sending app suggests, given
    /// the type's extension when it has none; the received file's own name
    /// otherwise.
    static func filename(suggested: String?, type: UTType, received: String) -> String {
        guard let suggested, !suggested.isEmpty else { return received }
        guard (suggested as NSString).pathExtension.isEmpty,
              let ext = type.preferredFilenameExtension else { return suggested }
        return "\(suggested).\(ext)"
    }

    /// The attachment's `Content-Type`. An image's own bytes decide, as for
    /// a photo picked from the library (#1140), since a name can claim one
    /// format and carry another; otherwise the name's extension, and
    /// `application/octet-stream` when that says nothing.
    static func mimeType(forFilename filename: String, data: Data) -> String {
        if let format = ImageDataFormat.detect(data) {
            return format.mimeType
        }
        let ext = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Reads each item it can and hands it to `model` as an attachment.
    /// Returns whether any item was taken.
    @MainActor
    static func take(_ providers: [NSItemProvider], into model: ComposeViewModel) -> Bool {
        var took = false
        for provider in providers {
            guard let type = readableType(
                registered: provider.registeredTypeIdentifiers,
                hasSuggestedName: provider.suggestedName != nil
            ) else { continue }
            took = true
            let suggested = provider.suggestedName
            // The file the provider writes is gone once this returns, so
            // the bytes are read here, off the main actor.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let name = filename(suggested: suggested, type: type, received: url.lastPathComponent)
                let mime = mimeType(forFilename: name, data: data)
                Task { @MainActor in
                    model.addAttachment(filename: name, mimeType: mime, data: data)
                }
            }
        }
        return took
    }
}

extension View {
    /// Takes files, images and messages dropped onto this part of a composer
    /// as attachments, and outlines it while one hovers. Apply to the form's
    /// rows: a `Form` passes a drop over its rows to the row, not to a
    /// modifier on the form itself. A text field takes text dropped on it
    /// first.
    func takesDroppedAttachments(into model: ComposeViewModel) -> some View {
        modifier(DroppedAttachmentTarget(model: model))
    }
}

private struct DroppedAttachmentTarget: ViewModifier {
    let model: ComposeViewModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.item], isTargeted: $isTargeted) { providers in
                // A composer frozen for a hand-off, or sending, takes nothing.
                guard model.holdsDraft, !model.isSending else { return false }
                return DroppedAttachment.take(providers, into: model)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
