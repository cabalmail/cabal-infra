import Foundation

/// Core Spotlight identity for one indexed message: the folder it lives in
/// plus its UID there. Deliberately *not* the RFC 5322 Message-ID — deletions
/// arrive as (folder, uid) pairs from the envelope cache, so the searchable
/// item's `uniqueIdentifier` must be reconstructable from those two alone.
/// The tap-routing path recovers the Message-ID from the envelope cache when
/// it builds the `NavState`, which keeps navigation robust to cross-client
/// moves without baking a third component into the identifier.
public struct SpotlightMessageRef: Sendable, Hashable {
    public let folder: String
    public let uid: UInt32

    public init(folder: String, uid: UInt32) {
        self.folder = folder
        self.uid = uid
    }

    private static let prefix = "cabalmail-msg"
    private static let version = "v1"

    /// Encodes as `cabalmail-msg|v1|<base64url folder>|<uid>`. The folder is
    /// base64url-encoded because IMAP folder names are user-controlled and
    /// could contain the `|` separator.
    public var stringValue: String {
        let encodedFolder = Data(folder.utf8).base64URLEncoded()
        return [Self.prefix, Self.version, encodedFolder, String(uid)].joined(separator: "|")
    }

    /// Parses an identifier produced by `stringValue`. Nil for anything else
    /// (activities from older builds, other apps' identifiers).
    public init?(string: String) {
        let parts = string.split(separator: "|", omittingEmptySubsequences: false)
        guard
            parts.count == 4,
            parts[0] == Self.prefix,
            parts[1] == Self.version,
            let folderData = Data(base64URLEncoded: String(parts[2])),
            let folder = String(data: folderData, encoding: .utf8),
            let uid = UInt32(parts[3])
        else { return nil }
        self.folder = folder
        self.uid = uid
    }
}

/// One message as donated to the on-device Spotlight index. A pure value
/// type so entry construction (title fallback, author extraction, snippet)
/// is testable without CoreSpotlight; the `CSSearchableItem` mapping lives
/// in `LiveSearchableIndex`'s file behind `canImport(CoreSpotlight)`.
public struct SpotlightEntry: Sendable, Hashable {
    public let ref: SpotlightMessageRef
    public let title: String
    public let authorNames: [String]
    public let authorEmailAddresses: [String]
    public let recipientNames: [String]
    public let recipientEmailAddresses: [String]
    public let date: Date?
    public let hasAttachments: Bool
    /// Plain-text body, present only after the user has read the message
    /// (bodies are never fetched just to index them).
    public let textContent: String?

    public init(envelope: Envelope, folder: String, textContent: String? = nil) {
        self.ref = SpotlightMessageRef(folder: folder, uid: envelope.uid)
        let subject = envelope.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = subject.isEmpty ? "(No subject)" : subject
        let authors = envelope.from.isEmpty ? envelope.sender : envelope.from
        self.authorNames = authors.compactMap(\.displayName)
        self.authorEmailAddresses = authors.map { "\($0.mailbox)@\($0.host)" }
        let recipients = envelope.to + envelope.cc
        self.recipientNames = recipients.compactMap(\.displayName)
        self.recipientEmailAddresses = recipients.map { "\($0.mailbox)@\($0.host)" }
        self.date = envelope.date ?? envelope.internalDate
        self.hasAttachments = envelope.hasAttachments
        self.textContent = textContent
    }

    /// Domain identifier = the folder path, so unsubscribing or deleting a
    /// folder is one `deleteDomains` call. Core Spotlight treats `.` in a
    /// domain identifier as a hierarchy separator; Dovecot's on-the-wire
    /// separator is `.` so folder *names* can't contain one, and the API
    /// layer re-delimits paths with `/` — the hierarchy semantics can never
    /// fire accidentally.
    public var domainIdentifier: String { ref.folder }

    public var uniqueIdentifier: String { ref.stringValue }

    /// Secondary line under the title in Spotlight results: a body snippet
    /// once the message has been read, else the sender.
    public var contentDescription: String? {
        if let snippet = Self.snippet(from: textContent) { return snippet }
        if let author = authorNames.first { return author }
        return authorEmailAddresses.first
    }

    /// First ~200 characters of the body with whitespace runs collapsed.
    private static func snippet(from text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(200))
    }
}

// MARK: - base64url

// RFC 4648 §5 without padding: the encoded folder rides inside a
// `|`-separated identifier, so `+`, `/`, and `=` are all swapped out.
extension Data {
    fileprivate func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
