import Foundation

/// Sort key for envelope listings. Mirrors the IMAP SORT criteria the
/// React webmail exposes (`react/admin/src/constants.js`): four fields
/// crossed with two directions, with the field defaulting to `dateReceived`
/// (ARRIVAL) descending — the standard "newest at top" Inbox order that
/// every previous caller assumed implicitly.
///
/// The wire encoding is the IMAP SORT syntax that
/// `lambda/api/list_messages/function.py` consumes: a concatenation of
/// `sort_order` (`"REVERSE "` or `""`) and `sort_field` (`"ARRIVAL"`,
/// `"DATE"`, `"FROM"`, `"SUBJECT"`).
public struct SortCriterion: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable, CaseIterable {
        /// IMAP ARRIVAL — server-side received timestamp. The historical
        /// Inbox default; survives time-zone confusion better than DATE.
        case dateReceived
        /// IMAP DATE — the `Date:` header value the sender wrote.
        case dateSent
        case from
        case subject

        /// IMAP SORT field token sent to the Lambda.
        public var wireField: String {
            switch self {
            case .dateReceived: return "ARRIVAL"
            case .dateSent:     return "DATE"
            case .from:         return "FROM"
            case .subject:      return "SUBJECT"
            }
        }
    }

    public enum Direction: String, Sendable, Hashable, CaseIterable {
        case descending
        case ascending

        /// IMAP SORT order prefix sent to the Lambda. Includes the
        /// trailing space when present so the concatenation with
        /// `wireField` matches `react/admin/src/constants.js`.
        public var wireOrder: String {
            switch self {
            case .descending: return "REVERSE "
            case .ascending:  return ""
            }
        }
    }

    public let field: Field
    public let direction: Direction

    public init(field: Field, direction: Direction) {
        self.field = field
        self.direction = direction
    }

    /// "Newest received first" — the conventional Inbox order and the
    /// implicit default before this enum existed.
    public static let `default` = SortCriterion(field: .dateReceived, direction: .descending)
}
