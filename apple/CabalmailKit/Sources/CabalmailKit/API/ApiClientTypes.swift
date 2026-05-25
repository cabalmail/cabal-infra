import Foundation

// MARK: - Wire types
//
// Response shapes for the Cabalmail Lambda API. Kept separate from
// `ApiClient.swift` (the protocol) and `URLSessionApiClient.swift` (the
// implementation) so each file stays under SwiftLint's `file_length`
// limit.

/// `/list_folders` response. The Lambda returns two flat string arrays:
/// every folder, plus the subset that's currently subscribed.
public struct ApiFolderList: Sendable, Codable, Hashable {
    public let folders: [String]
    public let subFolders: [String]

    private enum CodingKeys: String, CodingKey {
        case folders
        case subFolders = "sub_folders"
    }
}

public struct ApiFolderStatus: Sendable, Codable, Hashable {
    public let messages: Int?
    public let unseen: Int?
    public let uidValidity: UInt32?
    public let uidNext: UInt32?

    private enum CodingKeys: String, CodingKey {
        case messages
        case unseen
        case uidValidity = "uid_validity"
        case uidNext = "uid_next"
    }
}

/// One envelope as returned by `/list_envelopes`.
///
/// The Lambda flattens RFC 3501 ENVELOPE into stringified `mailbox@host`
/// addresses (no display names), a stringified date, a flag list, and the
/// raw BODYSTRUCTURE tree. Display name is unavailable on the wire — we
/// surface what we have and let the UI fall back to mailbox-only rendering
/// for messages that came through the API path.
public struct ApiEnvelope: Sendable, Codable, Hashable {
    public let id: UInt32
    public let date: String?
    public let subject: String?
    public let from: [String]
    public let to: [String]
    public let cc: [String]
    public let flags: [String]
    /// BODYSTRUCTURE expressed as a recursive list of strings / numbers.
    /// Decoded as JSON `Any`-equivalent and walked at the call site to
    /// detect attachments. Stored as a typed enum so it stays Sendable.
    public let structure: BodyStructureNode?
    public let priority: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, date, subject, from, to, cc, flags, priority
        case structure = "struct"
    }
}

/// JSON-tree representation of an IMAP BODYSTRUCTURE response. The Lambda
/// emits a recursive list-of-lists with leaves that are strings or
/// integers; this enum mirrors that shape so we can walk the tree and
/// detect attachments without parsing IMAP grammar on the client side.
public enum BodyStructureNode: Sendable, Codable, Hashable {
    case string(String)
    case integer(Int)
    case list([BodyStructureNode])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode([BodyStructureNode].self) {
            self = .list(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// True if the structure tree contains a part with disposition or
    /// content-type indicating an attachment. Heuristic only — used to
    /// drive the paperclip badge in the message list.
    public var hasAttachments: Bool {
        switch self {
        case .string(let value):
            let lower = value.lowercased()
            return lower == "attachment" || lower == "application"
        case .list(let children):
            return children.contains { $0.hasAttachments }
        case .integer, .null:
            return false
        }
    }
}

/// `/fetch_message` response. The raw RFC 822 lives behind `messageRaw`
/// (a presigned S3 URL); the Lambda also returns decoded text and HTML
/// bodies for the convenience of the React reader, which we keep in case
/// callers want to skip the second round-trip.
public struct ApiMessageBody: Sendable, Codable, Hashable {
    public let messageRaw: String?
    public let messageBodyPlain: String?
    public let messageBodyHtml: String?
    public let recipient: String?
    public let messageId: [String]?
    public let inReplyTo: [String]?
    public let references: [String]?

    private enum CodingKeys: String, CodingKey {
        case messageRaw = "message_raw"
        case messageBodyPlain = "message_body_plain"
        case messageBodyHtml = "message_body_html"
        case recipient
        case messageId = "message_id"
        case inReplyTo = "in_reply_to"
        case references
    }
}

public struct ApiAttachmentDescriptor: Sendable, Codable, Hashable {
    public let name: String?
    public let type: String?
    public let size: Int?
    public let id: Int
}

/// Structured query for `/search_envelopes`. Mirrors the keys the React
/// `ApiClient.searchEnvelopes(...)` wraps onto its axios call, so both
/// clients speak the same contract.
///
/// `folder == nil` triggers cross-folder mode. Date fields use day
/// granularity (the Lambda parses them as `YYYY-MM-DD`). Booleans send
/// `1` to satisfy the Lambda's TRUTHY check and are omitted otherwise.
public struct SearchQuery: Sendable, Hashable {
    public let folder: String?
    public let text: String?
    public let from: String?
    public let to: String?
    public let subject: String?
    public let since: Date?
    public let before: Date?
    public let unread: Bool
    public let flagged: Bool
    public let hasAttachment: Bool
    public let limit: Int?
    public let cursor: String?

    public init(
        folder: String? = nil,
        text: String? = nil,
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        since: Date? = nil,
        before: Date? = nil,
        unread: Bool = false,
        flagged: Bool = false,
        hasAttachment: Bool = false,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.folder = folder
        self.text = text
        self.from = from
        self.to = to
        self.subject = subject
        self.since = since
        self.before = before
        self.unread = unread
        self.flagged = flagged
        self.hasAttachment = hasAttachment
        self.limit = limit
        self.cursor = cursor
    }
}

/// `/search_envelopes` response. Each envelope is tagged with its source
/// folder (always set, even in single-folder mode) so operations on
/// cross-folder results can route per-row to the right mailbox.
public struct ApiSearchResponse: Sendable, Hashable {
    public let envelopes: [ApiSearchEnvelope]
    public let totalEstimate: Int
    public let nextCursor: String?
    public let foldersSearched: [String]
    public let truncated: Bool

    public init(
        envelopes: [ApiSearchEnvelope],
        totalEstimate: Int,
        nextCursor: String?,
        foldersSearched: [String],
        truncated: Bool
    ) {
        self.envelopes = envelopes
        self.totalEstimate = totalEstimate
        self.nextCursor = nextCursor
        self.foldersSearched = foldersSearched
        self.truncated = truncated
    }
}

/// One envelope as returned by `/search_envelopes` — the `/list_envelopes`
/// shape plus a `folder` field naming the source mailbox.
public struct ApiSearchEnvelope: Sendable, Hashable, Codable {
    public let id: UInt32
    public let date: String?
    public let subject: String?
    public let from: [String]
    public let to: [String]
    public let cc: [String]
    public let flags: [String]
    public let structure: BodyStructureNode?
    public let priority: [String]?
    public let folder: String

    private enum CodingKeys: String, CodingKey {
        case id, date, subject, from, to, cc, flags, priority, folder
        case structure = "struct"
    }

    public init(
        id: UInt32,
        date: String?,
        subject: String?,
        from: [String],
        to: [String],
        cc: [String],
        flags: [String],
        structure: BodyStructureNode?,
        priority: [String]?,
        folder: String
    ) {
        self.id = id
        self.date = date
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.flags = flags
        self.structure = structure
        self.priority = priority
        self.folder = folder
    }
}

/// `other_headers` sub-object carried by `/send`. Keys mirror the React
/// client's call shape so the Lambda stays a single endpoint.
public struct ApiSendOtherHeaders: Sendable, Codable, Hashable {
    public let messageId: [String]
    public let inReplyTo: [String]
    public let references: [String]

    public init(messageId: [String] = [], inReplyTo: [String] = [], references: [String] = []) {
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case inReplyTo = "in_reply_to"
        case references
    }
}
