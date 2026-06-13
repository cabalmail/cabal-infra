import Foundation

/// Why a compose session was opened. Carried explicitly on the seed
/// `Draft` so the compose view can route initial focus + reply-style
/// HTML scaffolding without depending on envelope-derived signals like
/// `inReplyTo` — a resumed or persisted draft can carry threading headers
/// without being a freshly-seeded reply, and envelopes cached before the
/// server surfaced Message-ID have none even for genuine replies.
public enum ComposeIntent: String, Sendable, Codable, Hashable {
    case new
    case reply
    case replyAll
    case forward
}

/// Server-side coordinates of a draft copy in the IMAP Drafts folder, as
/// reported by `/save_draft` (UIDPLUS APPENDUID). The pair is only
/// meaningful together — a UID can be reused after a mailbox reset bumps
/// UIDVALIDITY — so every replace / discard call sends both and the
/// Lambda's guard declines on mismatch.
public struct DraftServerRef: Sendable, Codable, Hashable {
    public let uid: UInt32
    public let uidValidity: UInt32

    public init(uid: UInt32, uidValidity: UInt32) {
        self.uid = uid
        self.uidValidity = uidValidity
    }
}

/// Locally-persisted compose state.
///
/// `DraftStore` autosaves drafts under the app support directory so a
/// mid-compose app kill is recoverable; it remains the live editing buffer.
/// Cross-device sync layers on top: compose pushes the buffer to the IMAP
/// `Drafts` folder via `/save_draft` (close-without-send, plus a long
/// debounce), recording `serverUid` / `serverUidValidity` so the next save
/// replaces the prior copy and a send discards it.
///
/// `EmailAddress` values are stored as their canonical string form and
/// re-parsed on load; this keeps the persisted shape stable even if the
/// struct grows new fields later.
public struct Draft: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var updatedAt: Date
    public var fromAddress: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    /// Optional so drafts persisted before this field existed still
    /// decode cleanly; `nil` is treated as `.new` at use sites.
    public var composeIntent: ComposeIntent?
    /// Coordinates of the server-side Drafts copy this draft was last
    /// saved to (or resumed from); nil for never-synced drafts. Stored as
    /// two optionals rather than a `DraftServerRef` so pre-sync persisted
    /// JSON decodes cleanly and the fields stay independently inspectable.
    public var serverUid: UInt32?
    public var serverUidValidity: UInt32?

    public init(
        id: UUID = UUID(),
        updatedAt: Date = Date(),
        fromAddress: String? = nil,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = "",
        inReplyTo: String? = nil,
        references: [String] = [],
        composeIntent: ComposeIntent? = nil,
        serverUid: UInt32? = nil,
        serverUidValidity: UInt32? = nil
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.fromAddress = fromAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.composeIntent = composeIntent
        self.serverUid = serverUid
        self.serverUidValidity = serverUidValidity
    }

    /// The server coordinates as a `DraftServerRef`, when both halves are
    /// present.
    public var serverRef: DraftServerRef? {
        guard let serverUid, let serverUidValidity else { return nil }
        return DraftServerRef(uid: serverUid, uidValidity: serverUidValidity)
    }

    /// A draft with no recipients, subject, or body is considered empty and
    /// the store drops it rather than persisting noise.
    public var isEmpty: Bool {
        fromAddress == nil
            && to.isEmpty && cc.isEmpty && bcc.isEmpty
            && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
