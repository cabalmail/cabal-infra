import SwiftUI
import UniformTypeIdentifiers
import CabalmailKit

/// Files, images and messages dropped onto the compose form become
/// attachments: from Files, Photos or another app beside Cabalmail in Split
/// View (the iPhone Duo spec), or from a Cabalmail message list in another
/// window, as an `.eml`. They take the same path as the photo and file
/// pickers, `ComposeViewModel.addAttachment`. The Mac compose window lays its
/// fields out without these rows and takes no drops yet.
///
/// Read through `NSItemProvider` rather than a `Transferable` drop: a
/// `FileRepresentation` import never matched a drag whose types are only
/// registered as data, which is how a message list offers its `.eml`
/// (measured on the iPhone Duo simulator), and the provider also carries the
/// file name the sending app suggests.
enum DroppedAttachment {
    /// The type to read an item as, or nil to leave it: a message's `.eml`
    /// first, then an image, then the item's first data type. Text, a link
    /// or rich content with no file name is a selection, not a file, and is
    /// left whole; so is a message list's move reference, which means nothing
    /// outside the list it came from.
    static func readableType(registered identifiers: [String], hasSuggestedName: Bool) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if let eml = types.first(where: { $0.conforms(to: .emailMessage) }) {
            return eml
        }
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            return image
        }
        let isSelection = types.contains {
            $0.conforms(to: .text) || $0.conforms(to: .url) || $0.conforms(to: .compositeContent)
        }
        guard hasSuggestedName || !isSelection else { return nil }
        return types.first {
            $0.conforms(to: .data) && !$0.conforms(to: .url) && $0 != .cabalmailMessageMove
        }
    }

    /// The attachment's file name: the one the sending app suggests, given
    /// the type's extension unless it already ends in one of that type's;
    /// the received file's own name when there is no suggestion.
    static func filename(suggested: String?, type: UTType, received: String) -> String {
        guard let suggested, !suggested.isEmpty else { return received }
        let ext = (suggested as NSString).pathExtension
        if !ext.isEmpty, let named = UTType(filenameExtension: ext), named.conforms(to: type) {
            return suggested
        }
        guard let typeExtension = type.preferredFilenameExtension else { return suggested }
        return "\(suggested).\(typeExtension)"
    }

    /// The attachment's `Content-Type`. An image's own bytes decide, as for
    /// a photo picked from the library (#1140), since a name can claim one
    /// format and carry another; otherwise the name's extension, and
    /// `application/octet-stream` when that says nothing. A message (`.eml`)
    /// goes as `application/octet-stream` too: the send path base64-encodes
    /// every attachment, and a `message/*` part may not be (RFC 2046).
    static func mimeType(forFilename filename: String, data: Data) -> String {
        if let format = ImageDataFormat.detect(data) {
            return format.mimeType
        }
        let ext = (filename as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType,
              !mime.hasPrefix("message/") else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Whether `model` takes a drop now: not while it is moving to a window,
    /// sending, or closing.
    @MainActor
    static func takesDrops(_ model: ComposeViewModel) -> Bool {
        model.holdsDraft && !model.isSending && !model.isFinishing
    }

    /// Starts reading each item it can, for `model` to attach when it
    /// arrives. Returns whether it started any. Send and the move to a window
    /// wait meanwhile (`pendingDrops`); one that arrives after the composer
    /// has moved, sent or closed is left, and one that can't be read says so.
    @MainActor
    static func take(_ providers: [NSItemProvider], into model: ComposeViewModel) -> Bool {
        let readable = providers.compactMap { provider in
            readableType(
                registered: provider.registeredTypeIdentifiers,
                hasSuggestedName: provider.suggestedName != nil
            ).map { (provider, $0) }
        }
        for (provider, type) in readable {
            model.pendingDrops += 1
            let suggested = provider.suggestedName
            // The file the provider writes is gone once this returns, so the
            // bytes are read here, off the main actor.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                let loaded = url.flatMap { url in
                    (try? Data(contentsOf: url)).map { data in
                        (filename(suggested: suggested, type: type, received: url.lastPathComponent), data)
                    }
                }
                Task { @MainActor in
                    model.pendingDrops -= 1
                    guard let loaded else {
                        model.errorMessage = "Couldn't attach \(suggested ?? "the dropped item")."
                        return
                    }
                    let (name, data) = loaded
                    guard takesDrops(model) else { return }
                    model.addAttachment(filename: name, mimeType: mimeType(forFilename: name, data: data), data: data)
                }
            }
        }
        return !readable.isEmpty
    }
}

extension View {
    /// Takes files, images and messages dropped onto this part of a composer
    /// as attachments, and outlines it while one it can take hovers. Apply to
    /// the form's rows: a `Form` passes a drop over its rows to the row, not
    /// to a modifier on the form itself.
    func takesDroppedAttachments(into model: ComposeViewModel) -> some View {
        modifier(DroppedAttachmentTarget(model: model))
    }
}

private struct DroppedAttachmentTarget: ViewModifier {
    let model: ComposeViewModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.item], delegate: DroppedAttachmentDelegate(model: model, isTargeted: $isTargeted))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Refuses, without an outline, a drag the composer would take nothing from.
private struct DroppedAttachmentDelegate: DropDelegate {
    let model: ComposeViewModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        DroppedAttachment.takesDrops(model) && info.itemProviders(for: [.item]).contains { provider in
            DroppedAttachment.readableType(
                registered: provider.registeredTypeIdentifiers,
                hasSuggestedName: provider.suggestedName != nil
            ) != nil
        }
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard DroppedAttachment.takesDrops(model) else { return false }
        return DroppedAttachment.take(info.itemProviders(for: [.item]), into: model)
    }
}
