import Foundation

/// RFC 3501 address pair — display name + mailbox@host.
public struct EmailAddress: Sendable, Codable, Hashable {
    public let name: String?
    public let mailbox: String
    public let host: String

    public init(name: String?, mailbox: String, host: String) {
        self.name = name
        self.mailbox = mailbox
        self.host = host
    }

    public var formatted: String {
        let addr = "\(mailbox)@\(host)"
        if let name, !name.isEmpty {
            return "\"\(name)\" <\(addr)>"
        }
        return addr
    }
}

/// IMAP FETCH ENVELOPE + FLAGS + INTERNALDATE + RFC822.SIZE, per RFC 3501.
public struct Envelope: Sendable, Codable, Hashable, Identifiable {
    public let uid: UInt32
    public let messageId: String?
    public let date: Date?
    public let subject: String?
    public let from: [EmailAddress]
    public let sender: [EmailAddress]
    public let replyTo: [EmailAddress]
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let inReplyTo: String?
    public let flags: Set<Flag>
    public let internalDate: Date?
    public let size: UInt32?
    public let hasAttachments: Bool

    public var id: UInt32 { uid }

    public init(
        uid: UInt32,
        messageId: String? = nil,
        date: Date? = nil,
        subject: String? = nil,
        from: [EmailAddress] = [],
        sender: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        inReplyTo: String? = nil,
        flags: Set<Flag> = [],
        internalDate: Date? = nil,
        size: UInt32? = nil,
        hasAttachments: Bool = false
    ) {
        self.uid = uid
        self.messageId = messageId
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
        self.hasAttachments = hasAttachments
    }
}
