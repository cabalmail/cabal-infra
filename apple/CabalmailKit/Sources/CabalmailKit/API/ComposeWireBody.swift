import Foundation

/// The compose fields `/send` and `/save_draft` take in common —
/// `SaveDraftRequest` is documented as "the `/send` shape minus SMTP
/// concerns", and both request builders spelled the same ten wire keys out
/// byte for byte. `composeJson` is that one copy.
///
/// Each endpoint still owns what is only its own: `/send` layers
/// `smtp_host` and `draft` on top plus its `discard_draft_*` pair, and
/// `/save_draft` its `replaces_*` pair.
protocol ComposeWireBody {
    var host: String { get }
    var sender: String { get }
    var toList: [String] { get }
    var ccList: [String] { get }
    var bccList: [String] { get }
    var subject: String { get }
    var otherHeaders: ApiSendOtherHeaders { get }
    var htmlBody: String { get }
    var textBody: String { get }
    var attachments: [ApiSendAttachment] { get }
}

extension SendMessageRequest: ComposeWireBody {}
extension SaveDraftRequest: ComposeWireBody {}

extension ComposeWireBody {
    /// The compose payload as the Lambdas expect it: snake_case keys, the
    /// threading headers nested under `other_headers`, and the already-
    /// uploaded attachments as `{filename, mime_type, s3_key}` objects.
    var composeJson: [String: Any] {
        let headersJson: [String: Any] = [
            "message_id": otherHeaders.messageId,
            "in_reply_to": otherHeaders.inReplyTo,
            "references": otherHeaders.references,
        ]
        let attachmentsJson: [[String: Any]] = attachments.map { attachment in
            [
                "filename": attachment.filename,
                "mime_type": attachment.mimeType,
                "s3_key": attachment.s3Key,
            ]
        }
        return [
            "host": host,
            "sender": sender,
            "to_list": toList,
            "cc_list": ccList,
            "bcc_list": bccList,
            "subject": subject,
            "other_headers": headersJson,
            "html": htmlBody,
            "text": textBody,
            "attachments": attachmentsJson,
        ]
    }
}
