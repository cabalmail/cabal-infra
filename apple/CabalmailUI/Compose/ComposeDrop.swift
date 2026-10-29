import SwiftUI
import UniformTypeIdentifiers
import CabalmailKit

/// Files, images and messages dropped onto the compose form or its body
/// become attachments: from Files, Photos or another app beside Cabalmail in
/// Split View (the iPhone Duo spec), or from a Cabalmail message list in
/// another window, as an `.eml`. They take the same path as the photo and
/// file pickers, `ComposeViewModel.addAttachment`. On the rich-text editor
/// the page reads the files and hands them over (`takeEditorDrops`): an
/// image dropped or pasted there shows inline instead, and goes inline on
/// the wire (`ComposeInlineImages`), while a drag that carries markup as
/// well, a selection from a page or a document, is still inserted. On the
/// Mac only the body takes drops: its compose window lays the header fields
/// out without these rows.
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

    /// Takes files dropped or pasted onto `model`'s rich-text editor. The
    /// editor page reads them and hands them over
    /// (`RichTextEditorController.fileDrops`) rather than inserting them,
    /// saying first how many are coming, which Send and the move to a window
    /// wait for (`pendingDrops`). That wait starts once WebKit has given the
    /// page the files, which for a message is after its source has been
    /// fetched.
    @MainActor
    static func takeEditorDrops(into model: ComposeViewModel) {
        let drops = model.editorController.fileDrops
        drops.onStarted = { [weak model] count in
            model?.pendingDrops += count
        }
        drops.onFile = { [weak model] file in
            guard let model else { return }
            Task { @MainActor in
                await take(file, into: model)
                model.pendingDrops -= 1
            }
        }
    }

    /// Shows an image the editor page read inline where it was dropped or
    /// pasted, attaches any other file, or says why it can't.
    @MainActor
    static func take(_ file: EditorFileDrops.File, into model: ComposeViewModel) async {
        let drops = model.editorController.fileDrops
        let shownName = file.name.isEmpty ? "the dropped item" : file.name
        switch file.contents {
        case .unreadable:
            model.errorMessage = "Couldn't attach \(shownName)."
        case .tooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            model.errorMessage = "Couldn't attach \(shownName): it's larger than \(size)."
        case .data(let data):
            guard takesDrops(model) else {
                await drops.forget(file)
                return
            }
            guard !isMoveReference(data) else {
                await drops.forget(file)
                // The body showed it would take the drag, so say why nothing came.
                model.errorMessage = "To attach messages, drag them one at a time."
                return
            }
            if let image = InlineImageEncoding.encode(data) {
                let contentID = model.inlineImages.add(image)
                if await drops.placeImage(file, contentID: contentID, alt: file.name) {
                    model.richMirrorsMarkdown = false
                    return
                }
                model.inlineImages.remove(contentID)
            } else {
                await drops.forget(file)
            }
            let filename = file.name.isEmpty ? "Attachment" : file.name
            model.addAttachment(filename: filename, mimeType: mimeType(forFilename: filename, data: data), data: data)
        }
    }

    /// Whether a file the editor page read is a message list's move reference
    /// (`MessageDragPayload`'s wire form). A drag of several messages offers
    /// nothing else, and the page reads whatever a drag offers as a file: a
    /// build whose single-message drags offered only the move reference
    /// attached it as a 123-byte file (iPhone Duo simulator). The form's rows
    /// leave it by its type (`readableType`).
    static func isMoveReference(_ data: Data) -> Bool {
        guard let reference = try? JSONDecoder().decode(MessageDragPayload.self, from: data) else { return false }
        return !reference.items.isEmpty
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
    /// the form's rows and the Markdown body: a `Form` passes a drop over its
    /// rows to the row, not to a modifier on the form itself.
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
