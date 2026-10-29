import Foundation
import CabalmailKit

/// The images shown inline in the Rich Text body, by the bare Content-ID
/// their `<img src="cid:...">` names: dropped or pasted there, or carried in
/// from a quoted, forwarded or resumed message. The editor page loads them
/// from here (`InlineImageSchemeHandler`). An image stays after it is
/// deleted from the body, so undo can bring it back; only those the sent
/// HTML still shows go on the wire (`attachments(shownIn:)`), where the
/// Lambda sends them inline beside the HTML.
struct ComposeInlineImages: Equatable {
    struct Image: Equatable {
        let contentID: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    private(set) var images: [Image] = []

    var byteCount: Int {
        images.reduce(0) { $0 + $1.data.count }
    }

    func image(for contentID: String) -> Image? {
        images.first { $0.contentID == contentID }
    }

    /// Adds an image dropped or pasted into the body under a new
    /// Content-ID, which it returns. The id and the name are the app's own:
    /// short enough for the header to carry as written, and a name that
    /// says nothing about an attachment, which `list_attachments` would
    /// otherwise list the part as.
    mutating func add(_ encoded: InlineImageEncoding.Encoded) -> String {
        let token = UUID().uuidString.lowercased()
        let contentID = "\(token)@cabalmail"
        images.append(Image(
            contentID: contentID,
            filename: "image-\(token.prefix(8)).\(encoded.format.filenameExtension)",
            mimeType: encoded.format.mimeType,
            data: encoded.data
        ))
        return contentID
    }

    mutating func remove(_ contentID: String) {
        images.removeAll { $0.contentID == contentID }
    }

    /// Takes a quoted, forwarded or resumed message's inline image under its
    /// own Content-ID. Returns false for an attachment that is not one: no
    /// Content-ID, or not an image.
    mutating func adopt(_ attachment: Attachment) -> Bool {
        guard let contentID = attachment.contentID, !contentID.isEmpty,
              attachment.mimeType.lowercased().hasPrefix("image/") else { return false }
        if image(for: contentID) == nil {
            images.append(Image(
                contentID: contentID,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: attachment.data
            ))
        }
        return true
    }

    /// The images `html` shows, as attachments carrying their Content-IDs.
    func attachments(shownIn html: String) -> [Attachment] {
        images.filter { Self.html(html, shows: $0.contentID) }.map { image in
            Attachment(filename: image.filename, mimeType: image.mimeType, data: image.data, contentID: image.contentID)
        }
    }

    /// Whether an `src` attribute in `html` names `cid:<contentID>`; text
    /// that mentions it shows nothing. The Lambda applies the same rule.
    static func html(_ html: String, shows contentID: String) -> Bool {
        let pattern = #"(?i:src)\s*=\s*(["'])(?i:cid):"#
            + NSRegularExpression.escapedPattern(for: contentID) + #"\1"#
        return html.range(of: pattern, options: .regularExpression) != nil
    }
}
