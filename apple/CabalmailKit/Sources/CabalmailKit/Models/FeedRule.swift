import Foundation

/// One user-defined feed rule, matching the wire shape `/set_rules` stores
/// in `feedRules` beside the mail rules (`lambda/api/set_rules/function.py`)
/// and the feed fetcher applies to each item it first inserts
/// (`lambda/api/_shared/rss_rules.py`). See `docs/mail-rules.md`, "Feed
/// rules".
///
/// A feed rule is a mail rule with the filing taken out: conditions and the
/// three marks, and no destination, forward, reply or "continue". Nothing is
/// filed, so every matching enabled rule applies and the list's order is
/// only how it is shown.
///
/// Decoding follows `Rule`: a missing key reads as the default the Lambda's
/// normalizer applies, and a condition `field` this build doesn't know
/// decodes to `.unknown`, carrying the wire value. Such a rule is kept
/// opaque, the editors render it read-only (`isEditable`), and a save of the
/// list re-emits it as it was (#1901).
public struct FeedRule: Codable, Identifiable, Hashable, Sendable {
    /// Condition fields. `feed` is not a text match: it holds one
    /// subscription id and matches it exactly (see `feedSubscriptionID`).
    public enum Field: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
        case feed, title, author, summary
        /// A field this build doesn't know, holding the wire value. Not in
        /// `allCases`, so no picker ever offers one.
        case unknown(String)

        public static let allCases: [Field] = [.feed, .title, .author, .summary]

        /// The fields a "contains" condition row offers: every known field
        /// but `feed`, which the editors show as the rule's scope.
        public static let textCases: [Field] = [.title, .author, .summary]

        public init(rawValue: String) {
            self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .feed: return "feed"
            case .title: return "title"
            case .author: return "author"
            case .summary: return "summary"
            case .unknown(let value): return value
            }
        }

        /// The wire value when this build doesn't know the field, else nil.
        public var unknownValue: String? {
            if case .unknown(let value) = self { return value }
            return nil
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// One trigger clause; a rule's conditions are ANDed. For `title`,
    /// `author` and `summary` the value is a case-insensitive "contains";
    /// for `feed` it is a subscription id. An empty list matches every new
    /// item in every feed.
    public struct Condition: Codable, Identifiable, Hashable, Sendable {
        public var field: Field
        public var value: String

        /// Local identity for list editing (SwiftUI `ForEach`); not part of
        /// the wire shape and excluded from equality so decoded lists
        /// compare by content.
        public let id: UUID

        public init(field: Field = .title, value: String = "", id: UUID = UUID()) {
            self.field = field
            self.value = value
            self.id = id
        }

        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey { case field, value }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            field = try container.decode(Field.self, forKey: .field)
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
            id = UUID()
        }

        public static func == (lhs: Condition, rhs: Condition) -> Bool {
            lhs.field == rhs.field && lhs.value == rhs.value
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(field)
            hasher.combine(value)
        }
    }

    /// Server-assigned (`r-` + 12 hex), in the same format as a mail rule's
    /// and unique across both lists. New local rules mint via
    /// `Rule.mintID()`; the Lambda keeps a well-formed, unseen client id.
    public var id: String
    public var name: String
    public var enabled: Bool
    public var conditions: [Condition]
    /// Sets the built-in flag (the item's `is_favorite`).
    public var flag: Bool
    /// Custom-flag slot atoms the rule sets. A slot no longer in the
    /// subscriber's flag list makes the fetcher skip the whole rule.
    public var flags: [String]
    public var markRead: Bool

    /// The condition fields this build doesn't know, in wire order. Empty
    /// for every rule the editors can render.
    public var unknownWireValues: [String] {
        conditions.compactMap(\.field.unknownValue)
    }

    /// Whether the editors may change this rule. False for a rule carrying
    /// a condition `field` this build doesn't know: it is listed,
    /// reorderable and deletable, and saved back unchanged.
    public var isEditable: Bool {
        unknownWireValues.isEmpty
    }

    /// Whether the rule marks anything. One that doesn't is accepted by the
    /// server and does nothing when it matches.
    public var hasAction: Bool {
        flag || markRead || !flags.isEmpty
    }

    /// The subscription the rule is limited to, or nil when it covers every
    /// feed. On the wire this is the rule's one `feed` condition (the server
    /// refuses a second). Setting it rewrites that condition in place, adds
    /// it at the head of the list, or, for nil, removes it.
    public var feedSubscriptionID: String? {
        get { conditions.first { $0.field == .feed }?.value }
        set {
            guard let newValue else {
                conditions.removeAll { $0.field == .feed }
                return
            }
            if let index = conditions.firstIndex(where: { $0.field == .feed }) {
                conditions[index].value = newValue
            } else {
                conditions.insert(Condition(field: .feed, value: newValue), at: 0)
            }
        }
    }

    public init(
        id: String = Rule.mintID(),
        name: String = "",
        enabled: Bool = true,
        conditions: [Condition] = [],
        flag: Bool = false,
        flags: [String] = [],
        markRead: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.flag = flag
        self.flags = flags
        self.markRead = markRead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Rule.mintID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        conditions = try container.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        flag = try container.decodeIfPresent(Bool.self, forKey: .flag) ?? false
        flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
        markRead = try container.decodeIfPresent(Bool.self, forKey: .markRead) ?? false
    }

    // Encoding is synthesized: every server that accepts `feedRules` knows
    // all seven keys, so none needs holding back the way `Rule` holds back
    // an empty `flags`.
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, conditions, flag, flags, markRead
    }
}
