import Foundation

/// IMAP message flag. Well-known system flags are first-class; server-defined
/// keywords preserve their raw form.
public enum Flag: Sendable, Hashable, Codable {
    case seen
    case answered
    case flagged
    case deleted
    case draft
    case recent
    case keyword(String)

    /// RFC 3501 wire representation.
    public var wireValue: String {
        switch self {
        case .seen:       return "\\Seen"
        case .answered:   return "\\Answered"
        case .flagged:    return "\\Flagged"
        case .deleted:    return "\\Deleted"
        case .draft:      return "\\Draft"
        case .recent:     return "\\Recent"
        case .keyword(let name): return name
        }
    }

    public init(wireValue raw: String) {
        switch raw.lowercased() {
        case "\\seen":      self = .seen
        case "\\answered":  self = .answered
        case "\\flagged":   self = .flagged
        case "\\deleted":   self = .deleted
        case "\\draft":     self = .draft
        case "\\recent":    self = .recent
        default:            self = .keyword(raw)
        }
    }
}

/// How a `UID STORE` applies flag changes.
public enum FlagOperation: Sendable, Hashable, Codable {
    case add     // `+FLAGS`
    case remove  // `-FLAGS`
    case replace // `FLAGS`

    public var wireValue: String {
        switch self {
        case .add:     return "+FLAGS"
        case .remove:  return "-FLAGS"
        case .replace: return "FLAGS"
        }
    }
}
