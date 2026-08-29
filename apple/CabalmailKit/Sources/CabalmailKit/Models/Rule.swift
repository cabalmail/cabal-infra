import Foundation

/// One user-defined mail rule, matching the wire shape stored by the
/// `/set_rules` Lambda (`lambda/api/set_rules/function.py`) and evaluated by
/// the IMAP tier's procmail compiler. See `docs/1.x/user-mail-rules-plan.md`.
///
/// Precedence is positional: the rule's index in `RuleSet.rules` is its
/// evaluation order, so reordering is just splicing the array and saving the
/// whole set (one PUT, no per-rule ordinals).
///
/// Decoding is tolerant of missing keys — absent fields read as the same
/// defaults the Lambda's normalizer applies — so an older server row never
/// fails the whole set. Unknown `field` / `action` values still fail the
/// decode deliberately: silently coercing them would rewrite the rule on the
/// next save.
public struct Rule: Codable, Identifiable, Hashable, Sendable {
    /// Condition fields. Five, not six: BCC recipients are stripped before a
    /// message is transmitted, so a BCC condition would silently never match
    /// (see the plan's "BCC is not offered").
    public enum Field: String, Codable, CaseIterable, Sendable {
        case from, to, cc, subject, body
    }

    /// The mutually-exclusive destination. `none` is the no-destination case
    /// (auxiliary actions still run); `archive` targets the user's existing
    /// `Archive` folder and is skipped by the compiler when there isn't one.
    public enum Action: String, Codable, CaseIterable, Sendable {
        case move, copy, delete, archive, none
    }

    /// One trigger clause; a rule's conditions are ANDed and the only
    /// operator is case-insensitive contains. An empty list matches every
    /// message.
    public struct Condition: Codable, Identifiable, Hashable, Sendable {
        public var field: Field
        public var value: String

        /// Local identity for list editing (SwiftUI `ForEach`); not part of
        /// the wire shape and excluded from equality so decoded sets compare
        /// by content.
        public let id: UUID

        public init(field: Field = .from, value: String = "", id: UUID = UUID()) {
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

    /// Server-assigned (`r-` + 12 hex). The Lambda keeps a well-formed,
    /// unseen client id so edits stay stable across saves; anything else is
    /// re-minted server-side. New local rules mint via `mintID()`.
    public var id: String
    public var name: String
    public var enabled: Bool
    public var conditions: [Condition]
    public var action: Action
    /// Destination when `action == .move`. Wire format is the `/`-delimited
    /// display path (`Folder.path`); the compiler maps it to Maildir form.
    public var moveFolder: String
    /// Destinations when `action == .copy`.
    public var copyFolders: [String]
    public var flag: Bool
    /// Custom-flag slot atoms this rule sets at delivery (rules-composition
    /// plan, decision 6); `flag` above stays the system `\Flagged`. Omitted
    /// from the wire when empty (see `encode(to:)`).
    public var flags: [String]
    public var markRead: Bool
    public var forward: [String]
    public var reply: Bool
    /// Plain text; required non-empty when `reply` is on.
    public var replyBody: String
    /// Spill-through: keep evaluating later rules after this one fires.
    public var continueToNext: Bool

    public init(
        id: String = Rule.mintID(),
        name: String = "",
        enabled: Bool = true,
        conditions: [Condition] = [],
        action: Action = .none,
        moveFolder: String = "",
        copyFolders: [String] = [],
        flag: Bool = false,
        flags: [String] = [],
        markRead: Bool = false,
        forward: [String] = [],
        reply: Bool = false,
        replyBody: String = "",
        continueToNext: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.action = action
        self.moveFolder = moveFolder
        self.copyFolders = copyFolders
        self.flag = flag
        self.flags = flags
        self.markRead = markRead
        self.forward = forward
        self.reply = reply
        self.replyBody = replyBody
        self.continueToNext = continueToNext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Rule.mintID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        conditions = try container.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? .none
        moveFolder = try container.decodeIfPresent(String.self, forKey: .moveFolder) ?? ""
        copyFolders = try container.decodeIfPresent([String].self, forKey: .copyFolders) ?? []
        flag = try container.decodeIfPresent(Bool.self, forKey: .flag) ?? false
        flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
        markRead = try container.decodeIfPresent(Bool.self, forKey: .markRead) ?? false
        forward = try container.decodeIfPresent([String].self, forKey: .forward) ?? []
        reply = try container.decodeIfPresent(Bool.self, forKey: .reply) ?? false
        replyBody = try container.decodeIfPresent(String.self, forKey: .replyBody) ?? ""
        continueToNext = try container.decodeIfPresent(Bool.self, forKey: .continueToNext) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, conditions, action, moveFolder, copyFolders
        case flag, flags, markRead, forward, reply, replyBody, continueToNext
    }

    /// Hand-rolled so an EMPTY `flags` stays off the wire: a server that
    /// predates the key rejects the whole set on it ("Unknown field."), so
    /// sending it unconditionally would break every rule save against a
    /// not-yet-upgraded deployment. A non-empty list (only authorable via
    /// the palette picker) rides normally; the server defaults a missing
    /// key to [], so omission never loses data.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(action, forKey: .action)
        try container.encode(moveFolder, forKey: .moveFolder)
        try container.encode(copyFolders, forKey: .copyFolders)
        try container.encode(flag, forKey: .flag)
        if !flags.isEmpty {
            try container.encode(flags, forKey: .flags)
        }
        try container.encode(markRead, forKey: .markRead)
        try container.encode(forward, forKey: .forward)
        try container.encode(reply, forKey: .reply)
        try container.encode(replyBody, forKey: .replyBody)
        try container.encode(continueToNext, forKey: .continueToNext)
    }

    /// A fresh id in the server's `r-` + 12 lowercase hex format. Minted
    /// client-side so a rule's identity survives its first round-trip (the
    /// Lambda keeps well-formed unseen ids).
    public static func mintID() -> String {
        "r-" + String((0..<12).map { _ in "0123456789abcdef".randomElement()! })
    }

    /// Truthful-Continue normalization
    /// (`docs/1.x/rules-composition-and-custom-flags-plan.md`, decision 2).
    /// A stored `move`/`archive` with spill-through predates the gated
    /// editor; the compiler emits the exact same copy block for it as for
    /// `copy`, so the editors render and save it as the Copy it is. A stored
    /// `delete` with spill-through drops the flag the compiler ignores.
    /// One-way and silent — the server and compiler stay permissive, so a
    /// set that is never re-saved keeps working unchanged.
    public func normalizingLegacyContinue() -> Rule {
        guard continueToNext else { return self }
        var rule = self
        switch action {
        case .move:
            rule.action = .copy
            rule.copyFolders = moveFolder.isEmpty ? [] : [moveFolder]
        case .archive:
            // The Archive action is an implicit move to the `Archive`
            // folder, so that is the folder the copy carries over.
            rule.action = .copy
            rule.copyFolders = ["Archive"]
        case .delete:
            rule.continueToNext = false
        case .copy, .none:
            break
        }
        return rule
    }
}

/// The whole ordered rule set as returned by `/get_rules` and `/set_rules`:
/// one row per user, `version` carrying optimistic concurrency.
public struct RuleSet: Codable, Equatable, Sendable {
    public var rules: [Rule]
    public var version: Int
    /// ISO 8601 server stamp; informational.
    public var updatedAt: String

    public init(rules: [Rule] = [], version: Int = 0, updatedAt: String = "") {
        self.rules = rules
        self.version = version
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case rules, version, updatedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

/// A `/set_rules` write lost the optimistic-concurrency race (HTTP 409):
/// another device saved first. The caller reloads via `/get_rules` (which
/// reads consistently, so the winning write is guaranteed visible) and
/// reapplies on top. `serverVersion` is the winning version when the 409
/// body carried one.
public struct RuleSetConflictError: Error, Equatable, Sendable {
    public let serverVersion: Int?

    public init(serverVersion: Int?) {
        self.serverVersion = serverVersion
    }
}
