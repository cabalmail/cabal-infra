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
