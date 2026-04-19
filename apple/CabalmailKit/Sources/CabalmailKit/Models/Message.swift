import Foundation

/// Raw RFC 822 message as returned by `UID FETCH BODY.PEEK[]`.
///
/// MIME parsing happens in Phase 4 (`Cabalmail/Views/MessageDetailView.swift`),
/// not in `CabalmailKit` — the transport layer stays byte-accurate so the
/// renderer sees exactly what the server sent.
public struct RawMessage: Sendable, Codable, Hashable {
    public let uid: UInt32
    public let bytes: Data
    public let flags: Set<Flag>

    public init(uid: UInt32, bytes: Data, flags: Set<Flag> = []) {
        self.uid = uid
        self.bytes = bytes
        self.flags = flags
    }
}

/// Outbound message, used both by `SmtpClient.send(_:)` and IMAP `APPEND`
/// for draft storage. Rich-text rendering, quoting, and inline attachments
/// are the caller's responsibility — `SmtpClient` emits exactly the payload
/// it is handed.
public struct OutgoingMessage: Sendable, Codable, Hashable {
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [Attachment]
    public let extraHeaders: [String: String]
    /// Message-ID to stamp on the outgoing RFC 5322 payload. When nil,
    /// `SmtpClient` generates a random one at send time. Callers that need
    /// the Sent-folder copy to match the wire copy (see
    /// `CabalmailClient.send(_:)`) pass a pre-generated value here.
    public let messageId: String?

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        textBody: String? = nil,
        htmlBody: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [Attachment] = [],
        extraHeaders: [String: String] = [:],
        messageId: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.extraHeaders = extraHeaders
        self.messageId = messageId
    }
}

public struct Attachment: Sendable, Codable, Hashable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}
