import Foundation

/// The result of classifying a parsed MIME tree into the two things the
/// reader UI cares about: a list of downloadable attachment parts and a
/// map of `cid:` → embedded `data:` URL for inline images.
///
/// These are drawn from two *independent* rules, matching the web/Lambda
/// API exactly:
///
/// - **Attachment** — the part carries `Content-Disposition: attachment`,
///   or is a non-text, non-multipart leaf (`list_attachments` keys on the
///   disposition; the leaf fallback covers senders that omit it).
/// - **Inline image** — the part is an `image/*` leaf with a `Content-ID`
///   (`fetch_inline_image` keys purely on Content-ID).
///
/// A single part can satisfy both: Gmail stamps a `Content-ID` on genuine
/// `attachment`-disposition images. Such a part is registered as an inline
/// image *and* listed as a downloadable attachment — keying "inline" purely
/// off the presence of a Content-ID would otherwise hide every such image
/// from the attachment strip (the bug this split fixes).
public struct MimeAttachmentPlan: Sendable, Equatable {
    /// A downloadable attachment. `filename` is the sender-declared name
    /// (`Content-Disposition` filename, falling back to the `Content-Type`
    /// `name` parameter); nil when the sender declared neither, leaving the
    /// caller to synthesize one.
    public struct Attachment: Sendable, Equatable {
        public let filename: String?
        public let mimeType: String
        public let contentID: String?
        public let data: Data

        public init(filename: String?, mimeType: String, contentID: String?, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.contentID = contentID
            self.data = data
        }
    }

    public let attachments: [Attachment]
    public let inlineImages: [String: URL]

    public init(attachments: [Attachment], inlineImages: [String: URL]) {
        self.attachments = attachments
        self.inlineImages = inlineImages
    }
}

public extension MimePart {
    /// Whether this leaf part should be surfaced to the user as an
    /// attachment-or-inline candidate: an explicit `attachment` disposition,
    /// or any non-text, non-multipart leaf. The rendered `text/plain` and
    /// `text/html` alternatives are excluded — they are the message body.
    var isAttachmentCandidate: Bool {
        if contentDisposition?.isAttachment == true { return true }
        if contentType.isText, contentType.subtype == "plain" { return false }
        if contentType.isText, contentType.subtype == "html" { return false }
        return !contentType.isMultipart
    }

    /// Classify this part tree into downloadable attachments and inline
    /// `cid:` images. See `MimeAttachmentPlan` for the rules.
    func attachmentPlan() -> MimeAttachmentPlan {
        var attachments: [MimeAttachmentPlan.Attachment] = []
        var inlineImages: [String: URL] = [:]
        for leaf in leafParts where leaf.isAttachmentCandidate {
            // Register the inline `cid:` mapping so `cid:` refs in the body
            // still resolve, but only *skip* the attachment listing when the
            // part isn't explicitly flagged as an attachment. See the type doc.
            if let contentID = leaf.contentID, let dataURL = leaf.inlineImageDataURL {
                inlineImages[contentID] = dataURL
                if leaf.contentDisposition?.isAttachment != true { continue }
            }
            attachments.append(MimeAttachmentPlan.Attachment(
                filename: leaf.contentDisposition?.filename ?? leaf.contentType.name,
                mimeType: leaf.contentType.mimeType,
                contentID: leaf.contentID,
                data: leaf.decodedBody
            ))
        }
        return MimeAttachmentPlan(attachments: attachments, inlineImages: inlineImages)
    }
}
