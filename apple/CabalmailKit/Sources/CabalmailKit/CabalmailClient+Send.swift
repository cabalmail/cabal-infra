import Foundation

/// `/send` wire helpers split out of `CabalmailClient.swift` to keep the
/// main file under the SwiftLint `file_length` ceiling. Both the
/// foreground `send(_:)` / `saveDraft(_:)` paths and `SendQueue`'s retry
/// closure call `submit(...)` here so a queued message ships through the
/// same path as a fresh one.
extension CabalmailClient {
    /// Shared `/send` invocation used by both the foreground send path
    /// and `SendQueue`'s retry closure. Lives on the type so the queue
    /// closure doesn't capture `self`.
    ///
    /// Attachments are staged to S3 via `/upload_url` first so the
    /// /send request itself stays well under API Gateway's 10 MB
    /// proxy-request ceiling.
    static func submit(
        _ message: OutgoingMessage,
        api: ApiClient,
        imapHost: String,
        smtpHost: String,
        draft: Bool = false
    ) async throws {
        let headers = ApiSendOtherHeaders(
            messageId: message.messageId.map { [$0] } ?? [],
            inReplyTo: message.inReplyTo.map { [$0] } ?? [],
            references: message.references
        )
        var wireAttachments: [ApiSendAttachment] = []
        if !message.attachments.isEmpty {
            let slots = message.attachments.map {
                AttachmentUploadSlot(filename: $0.filename, mimeType: $0.mimeType)
            }
            let uploads = try await api.requestAttachmentUploads(host: imapHost, files: slots)
            for (attachment, upload) in zip(message.attachments, uploads) {
                try await api.uploadAttachment(
                    url: upload.url,
                    mimeType: attachment.mimeType,
                    data: attachment.data
                )
                wireAttachments.append(ApiSendAttachment(
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    s3Key: upload.key
                ))
            }
        }
        try await api.sendMessage(SendMessageRequest(
            host: imapHost,
            smtpHost: smtpHost,
            sender: "\(message.from.mailbox)@\(message.from.host)",
            toList: message.to.map { "\($0.mailbox)@\($0.host)" },
            ccList: message.cc.map { "\($0.mailbox)@\($0.host)" },
            bccList: message.bcc.map { "\($0.mailbox)@\($0.host)" },
            subject: message.subject,
            otherHeaders: headers,
            htmlBody: message.htmlBody ?? "",
            textBody: message.textBody ?? "",
            draft: draft,
            attachments: wireAttachments
        ))
    }

    /// Classifies which SMTP failures should fall through to the outbox.
    ///
    /// `network` / `transport` / `timeout` / `cancelled` are transient —
    /// retrying when the connection returns has a real chance of
    /// succeeding. `invalidCredentials`, `smtpCommandFailed`, and the rest
    /// are application-level and surface to the user immediately.
    static func shouldQueue(_ error: CabalmailError) -> Bool {
        switch error {
        case .network, .transport, .timeout, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Outcome of a `CabalmailClient.send(_:)` call. The compose UI branches
/// on this so an offline send shows "queued — will send when back
/// online" instead of a generic success toast.
public enum SendOutcome: Sendable, Equatable {
    case sent
    case queued(UUID)
}
