import Foundation

/// Parsed RFC 5322 header line. `value` has RFC 2047 encoded-words decoded
/// and any header-folding whitespace collapsed to a single space.
public struct MimeHeader: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Parsed `Content-Type: type/subtype; key=value; ...`.
public struct MimeContentType: Sendable, Hashable {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]

    public init(type: String, subtype: String, parameters: [String: String] = [:]) {
        self.type = type.lowercased()
        self.subtype = subtype.lowercased()
        self.parameters = parameters
    }

    public var mimeType: String { "\(type)/\(subtype)" }
    public var charset: String? { parameters["charset"] }
    public var boundary: String? { parameters["boundary"] }
    public var name: String? { parameters["name"] }
    public var isMultipart: Bool { type == "multipart" }
    public var isText: Bool { type == "text" }

    public static let defaultPlainText = MimeContentType(
        type: "text", subtype: "plain", parameters: ["charset": "us-ascii"]
    )
}

/// Parsed `Content-Disposition: type; filename=...`.
public struct MimeContentDisposition: Sendable, Hashable {
    public let type: String
    public let parameters: [String: String]

    public init(type: String, parameters: [String: String] = [:]) {
        self.type = type.lowercased()
        self.parameters = parameters
    }

    public var filename: String? { parameters["filename"] }
    public var isAttachment: Bool { type == "attachment" }
}

/// Supported Content-Transfer-Encoding values.
public enum MimeEncoding: String, Sendable, Hashable {
    case sevenBit = "7bit"
    case eightBit = "8bit"
    case binary
    case base64
    case quotedPrintable = "quoted-printable"

    public init(raw: String?) {
        let normalized = (raw ?? "7bit").lowercased()
        self = MimeEncoding(rawValue: normalized) ?? .sevenBit
    }
}

/// A single MIME part. For `multipart/*` types, `children` is populated and
/// `decodedBody` is empty. For leaf parts, the reverse.
public struct MimePart: Sendable, Hashable {
    public let headers: [MimeHeader]
    public let contentType: MimeContentType
    public let contentDisposition: MimeContentDisposition?
    public let contentID: String?
    public let encoding: MimeEncoding
    public let decodedBody: Data
    public let children: [MimePart]

    public init(
        headers: [MimeHeader],
        contentType: MimeContentType,
        contentDisposition: MimeContentDisposition?,
        contentID: String?,
        encoding: MimeEncoding,
        decodedBody: Data,
        children: [MimePart]
    ) {
        self.headers = headers
        self.contentType = contentType
        self.contentDisposition = contentDisposition
        self.contentID = contentID
        self.encoding = encoding
        self.decodedBody = decodedBody
        self.children = children
    }

    /// Convenience: find the first descendant matching `predicate`. Used
    /// by the renderer to pick a `text/html` alternative over `text/plain`.
    public func firstPart(where predicate: (MimePart) -> Bool) -> MimePart? {
        if predicate(self) { return self }
        for child in children {
            if let match = child.firstPart(where: predicate) { return match }
        }
        return nil
    }

    /// Flatten the leaf parts (non-multipart). Used to collect attachments.
    public var leafParts: [MimePart] {
        if contentType.isMultipart {
            return children.flatMap { $0.leafParts }
        }
        return [self]
    }

    /// Returns `decodedBody` as a `String` using the charset declared in
    /// Content-Type, falling back to UTF-8 and then ISO-8859-1. Returns nil
    /// for non-text parts.
    public func textContent() -> String? {
        guard contentType.isText else { return nil }
        let charset = contentType.charset?.lowercased() ?? "utf-8"
        let encoding: String.Encoding
        switch charset {
        case "utf-8", "utf8":               encoding = .utf8
        case "iso-8859-1", "latin1":        encoding = .isoLatin1
        case "us-ascii", "ascii":           encoding = .ascii
        case "windows-1252":                encoding = .windowsCP1252
        default:                            encoding = .utf8
        }
        if let text = String(bytes: decodedBody, encoding: encoding) { return text }
        return String(bytes: decodedBody, encoding: .isoLatin1)
    }
}
