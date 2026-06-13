import Foundation

/// `/send` + `/save_draft` wire helpers split out of `CabalmailClient.swift`
/// to keep the main file under the SwiftLint `file_length` ceiling. Both the
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
    ///
    /// `discardingDraft` carries the server-side Drafts copy a
    /// send-from-draft supersedes; the Lambda expunges it best-effort
    /// after successful SMTP delivery. Queued sends drop the ref (the
    /// outbox persists only the message), so the worst offline outcome is
    /// a stale draft copy — never a lost message.
    static func submit(
        _ message: OutgoingMessage,
        api: ApiClient,
        imapHost: String,
        smtpHost: String,
        draft: Bool = false,
        discardingDraft: DraftServerRef? = nil
    ) async throws {
        let wireAttachments = try await stageAttachments(message, api: api, imapHost: imapHost)
        try await api.sendMessage(SendMessageRequest(
            host: imapHost,
            smtpHost: smtpHost,
            sender: "\(message.from.mailbox)@\(message.from.host)",
            toList: message.to.map { "\($0.mailbox)@\($0.host)" },
            ccList: message.cc.map { "\($0.mailbox)@\($0.host)" },
            bccList: message.bcc.map { "\($0.mailbox)@\($0.host)" },
            subject: message.subject,
            otherHeaders: wireHeaders(for: message),
            htmlBody: message.htmlBody ?? "",
            textBody: message.textBody ?? "",
            draft: draft,
            attachments: wireAttachments,
            discardDraftUid: discardingDraft?.uid,
            discardDraftUidValidity: discardingDraft?.uidValidity
        ))
    }

    /// Shared `/save_draft` invocation behind `CabalmailClient.saveDraft`.
    /// Same compose payload as `submit(...)`, plus the replace coordinates.
    static func submitDraft(
        _ message: OutgoingMessage,
        api: ApiClient,
        imapHost: String,
        replacing prior: DraftServerRef?
    ) async throws -> ApiSaveDraftResponse {
        let wireAttachments = try await stageAttachments(message, api: api, imapHost: imapHost)
        return try await api.saveDraft(SaveDraftRequest(
            host: imapHost,
            sender: "\(message.from.mailbox)@\(message.from.host)",
            toList: message.to.map { "\($0.mailbox)@\($0.host)" },
            ccList: message.cc.map { "\($0.mailbox)@\($0.host)" },
            bccList: message.bcc.map { "\($0.mailbox)@\($0.host)" },
            subject: message.subject,
            otherHeaders: wireHeaders(for: message),
            htmlBody: message.htmlBody ?? "",
            textBody: message.textBody ?? "",
            attachments: wireAttachments,
            replacesUid: prior?.uid,
            replacesUidValidity: prior?.uidValidity
        ))
    }

    /// Uploads each attachment to a presigned `/upload_url` slot and
    /// returns the wire references the compose endpoints expect.
    static func stageAttachments(
        _ message: OutgoingMessage,
        api: ApiClient,
        imapHost: String
    ) async throws -> [ApiSendAttachment] {
        guard !message.attachments.isEmpty else { return [] }
        let slots = message.attachments.map {
            AttachmentUploadSlot(filename: $0.filename, mimeType: $0.mimeType)
        }
        let uploads = try await api.requestAttachmentUploads(host: imapHost, files: slots)
        var wireAttachments: [ApiSendAttachment] = []
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
        return wireAttachments
    }

    /// Assembles the `other_headers` payload, normalizing every message-id
    /// to its angle-bracketed wire form. `ReplyBuilder` and persisted
    /// `Draft`s carry bare ids; RFC 5322 (and the React client) put `<...>`
    /// on the wire, and the Lambda writes header values verbatim — this
    /// seam is the one place all senders (fresh, queued, draft) pass
    /// through.
    static func wireHeaders(for message: OutgoingMessage) -> ApiSendOtherHeaders {
        ApiSendOtherHeaders(
            messageId: message.messageId.flatMap(angleWrapped).map { [$0] } ?? [],
            inReplyTo: message.inReplyTo.flatMap(angleWrapped).map { [$0] } ?? [],
            references: message.references.compactMap(angleWrapped)
        )
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

/// Wraps a message-id token in angle brackets unless it already carries
/// them; empty tokens map to nil so they drop off the wire entirely.
private func angleWrapped(_ id: String) -> String? {
    let trimmed = id.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return trimmed }
    return "<\(trimmed)>"
}

/// Outcome of a `CabalmailClient.send(_:)` call. The compose UI branches
/// on this so an offline send shows "queued — will send when back
/// online" instead of a generic success toast.
public enum SendOutcome: Sendable, Equatable {
    case sent
    case queued(UUID)
}
