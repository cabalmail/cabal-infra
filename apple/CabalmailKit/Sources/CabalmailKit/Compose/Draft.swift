import Foundation

/// Locally-persisted compose state.
///
/// Phase 5 keeps drafts local only — `DraftStore` autosaves them under the app
/// support directory so a mid-compose app kill is recoverable. The plan's
/// IMAP-backed cross-device draft sync lives in Phase 5.1.
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
        references: [String] = []
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
