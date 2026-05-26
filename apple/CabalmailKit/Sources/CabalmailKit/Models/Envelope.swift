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

    /// Display name with any wrapping double-quotes stripped. Some IMAP
    /// servers return the RFC 5322 phrase verbatim in addr-name (Dovecot
    /// for one), so a `From: "Alice Smith" <a@x>` would otherwise render
    /// as `"Alice Smith"` in the UI. The parser also strips these on the
    /// way in; this property is a defense for cached envelopes captured
    /// before that change.
    public var displayName: String? {
        guard let name, !name.isEmpty else { return nil }
        if name.count >= 2, name.first == "\"", name.last == "\"" {
            return String(name.dropFirst().dropLast())
        }
        return name
    }

    public var formatted: String {
        let addr = "\(mailbox)@\(host)"
        if let displayName {
            return "\"\(displayName)\" <\(addr)>"
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

    /// True when the sender marked the message as high priority via the
    /// `X-Priority` / `Importance` / `Priority` headers. Mirrors React's
    /// `priority-1` / `priority-2` interpretation (see
    /// `react/admin/src/Email/Messages/Envelope.jsx`). Surfaced as a
    /// single Bool because the visible UI is also binary — the message
    /// either gets an importance badge or it doesn't. Defaults to false
    /// so cached envelopes captured before this field existed decode
    /// against the previous schema without losing the rest of the
    /// snapshot.
    public let isImportant: Bool

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
        hasAttachments: Bool = false,
        isImportant: Bool = false
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
        self.isImportant = isImportant
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uid = try container.decode(UInt32.self, forKey: .uid)
        self.messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        self.date = try container.decodeIfPresent(Date.self, forKey: .date)
        self.subject = try container.decodeIfPresent(String.self, forKey: .subject)
        self.from = try container.decodeIfPresent([EmailAddress].self, forKey: .from) ?? []
        self.sender = try container.decodeIfPresent([EmailAddress].self, forKey: .sender) ?? []
        self.replyTo = try container.decodeIfPresent([EmailAddress].self, forKey: .replyTo) ?? []
        self.to = try container.decodeIfPresent([EmailAddress].self, forKey: .to) ?? []
        self.cc = try container.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? []
        self.bcc = try container.decodeIfPresent([EmailAddress].self, forKey: .bcc) ?? []
        self.inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        self.flags = try container.decodeIfPresent(Set<Flag>.self, forKey: .flags) ?? []
        self.internalDate = try container.decodeIfPresent(Date.self, forKey: .internalDate)
        self.size = try container.decodeIfPresent(UInt32.self, forKey: .size)
        self.hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments) ?? false
        // Defaulting `isImportant` here lets snapshots written by versions
        // before this field landed decode cleanly — the alternative (whole-
        // snapshot decode failure followed by a refetch) is correct but
        // costs the user a wait on every first launch after the upgrade.
        self.isImportant = try container.decodeIfPresent(Bool.self, forKey: .isImportant) ?? false
    }
}
