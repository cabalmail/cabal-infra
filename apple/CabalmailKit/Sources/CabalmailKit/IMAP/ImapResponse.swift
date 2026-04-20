import Foundation

/// A single IMAP response line as parsed from the wire.
///
/// Coverage is scoped to what the Phase 3 client needs: status responses,
/// mailbox data (`LIST`, `LSUB`, `STATUS`, `SEARCH`, `EXISTS`, `EXPUNGE`),
/// and message data (`FETCH`). Rarely-used responses fall through to `other`
/// and are ignored by the command dispatchers.
public enum ImapResponse: Sendable, Equatable {
    /// Tagged completion: `<tag> OK | NO | BAD <text>`.
    case completion(tag: String, status: ImapStatus, text: String)

    /// Untagged `* OK | NO | BAD | BYE | PREAUTH <text>`.
    case status(code: ImapStatus, text: String)

    /// Untagged `* CAPABILITY <tokens...>`.
    case capability([String])

    /// Untagged `* LIST (<attrs>) "<delim>" "<mailbox>"` — or `LSUB`.
    case list(attributes: [String], delimiter: String, mailbox: String)
    case lsub(attributes: [String], delimiter: String, mailbox: String)

    /// Untagged `* STATUS "<mailbox>" (<attr> <value> ...)`.
    case status2(mailbox: String, attributes: [String: UInt64])

    /// Untagged `* SEARCH <n>...`.
    case search([UInt32])

    /// Untagged `* <n> EXISTS` / `EXPUNGE` / `RECENT`.
    case exists(UInt32)
    case expunge(UInt32)
    case recent(UInt32)

    /// Untagged `* <seq> FETCH (...)`. Fields are the parsed attribute pairs
    /// — clients interpret what they need (`UID`, `FLAGS`, `ENVELOPE`, etc.).
    case fetch(sequence: UInt32, attributes: ImapFetchAttributes)

    /// Continuation response `+ <text>`; used during `APPEND` and `IDLE`.
    case continuation(String)

    /// Any other untagged line we don't explicitly parse.
    case other(String)
}

public enum ImapStatus: String, Sendable, Equatable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
    case bye = "BYE"
    case preauth = "PREAUTH"
}

/// Parsed `FETCH` attribute values. Every field is optional because any
/// individual FETCH response only includes what the client asked for.
public struct ImapFetchAttributes: Sendable, Equatable {
    public var uid: UInt32?
    public var flags: Set<Flag>?
    public var internalDate: Date?
    public var rfc822Size: UInt32?
    public var envelope: ImapEnvelopeFields?
    public var body: Data?
    public var hasAttachments: Bool?

    public init(
        uid: UInt32? = nil,
        flags: Set<Flag>? = nil,
        internalDate: Date? = nil,
        rfc822Size: UInt32? = nil,
        envelope: ImapEnvelopeFields? = nil,
        body: Data? = nil,
        hasAttachments: Bool? = nil
    ) {
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.rfc822Size = rfc822Size
        self.envelope = envelope
        self.body = body
        self.hasAttachments = hasAttachments
    }
}

public struct ImapEnvelopeFields: Sendable, Equatable {
    public var date: Date?
    public var subject: String?
    public var from: [EmailAddress]
    public var sender: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var inReplyTo: String?
    public var messageId: String?

    public init(
        date: Date? = nil,
        subject: String? = nil,
        from: [EmailAddress] = [],
        sender: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        inReplyTo: String? = nil,
        messageId: String? = nil
    ) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageId = messageId
    }
}
