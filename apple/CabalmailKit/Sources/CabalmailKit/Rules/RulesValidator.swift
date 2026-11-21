import Foundation

/// Client-side mirror of the `/set_rules` Lambda's write-time validation
/// (`lambda/api/set_rules/function.py`), so the editors can flag a problem
/// inline before a PUT instead of round-tripping for a 400. Keep the two in
/// lockstep: every length cap, character rule, and message here corresponds
/// to a server check, and lengths count Unicode scalars to match Python's
/// code-point `len()`.
///
/// One deliberate divergence: invalid forward addresses are *issues* here but
/// are silently stripped (not rejected) server-side — the editors allow
/// half-typed chips locally, and flagging them client-side is what keeps the
/// server's stripping a dead code path.
///
/// A second deliberate divergence, client-strict rather than client-loose:
/// a rule with no effect (see `hasNoEffect`) is an issue here although the
/// server accepts it — the compiler would silently drop it
/// (`compile_skip_rule reason=no_effect`), and nothing constructible in an
/// editor may evaporate at compile time
/// (`docs/1.x/rules-composition-and-custom-flags-plan.md`, Phase 1).
public enum RulesValidator {
    public static let maxRules = 100
    public static let maxNameLength = 100
    public static let maxConditions = 10
    public static let maxValueLength = 500
    public static let maxForwards = 10
    public static let maxCopyFolders = 10
    public static let maxAddressLength = 320
    public static let maxReplyBodyLength = 4000
    public static let maxFolderLength = 255
    public static let maxRuleFlags = 20

    /// One structured finding, mirroring the Lambda's
    /// `{rule, field, error}` entries. `ruleIndex` is nil for set-level
    /// findings (the rule-count cap). `list` is nil for a mail rule and
    /// `"feedRules"` for a feed rule, as in the Lambda's entries: it says
    /// which list `ruleIndex` counts in.
    public struct Issue: Equatable, Sendable {
        public let list: String?
        public let ruleIndex: Int?
        public let field: String
        public let message: String

        public init(list: String? = nil, ruleIndex: Int?, field: String, message: String) {
            self.list = list
            self.ruleIndex = ruleIndex
            self.field = field
            self.message = message
        }
    }

    /// Validates the whole ordered set; empty means the server will accept it
    /// verbatim (no 400, nothing stripped).
    public static func validate(_ rules: [Rule]) -> [Issue] {
        var issues: [Issue] = []
        if rules.count > maxRules {
            issues.append(Issue(
                ruleIndex: nil, field: "rules", message: "At most \(maxRules) rules."
            ))
        }
        for (index, rule) in rules.enumerated() {
            issues += validate(rule, at: index)
        }
        return issues
    }

    /// Validates one rule. `index` only labels the returned issues.
    ///
    /// A rule this build can't render (`Rule.isEditable` false — a `field`
    /// or `action` newer than the app) is never an issue: it is round-tripped
    /// verbatim, the server that wrote it owns its validation, and flagging
    /// it here would hold the whole set's save hostage to a rule nothing
    /// local can fix (#1901).
    public static func validate(_ rule: Rule, at index: Int = 0) -> [Issue] {
        guard rule.isEditable else { return [] }
        var issues = scalarIssues(rule, at: index)
        issues += conditionIssues(rule.conditions.map(\.value), at: index)
        issues += copyFolderIssues(rule.copyFolders, at: index)
        issues += forwardIssues(rule.forward, at: index)
        issues += ruleFlagsIssues(rule.flags, at: index)
        if hasNoEffect(rule) {
            issues.append(Issue(
                ruleIndex: index, field: "continueToNext",
                message: "A rule that continues must file, flag, mark read, forward, or reply "
                    + "— this one would have no effect."
            ))
        }
        return issues
    }

    /// A continuing rule that neither files (a destination that delivers),
    /// decorates (flag / custom flags / mark-as-read arm the compiler's
    /// pending state — the rules-composition plan's decisions 3 and 6),
    /// forwards, nor replies compiles to an empty procmail block and is
    /// dropped.
    public static func hasNoEffect(_ rule: Rule) -> Bool {
        rule.continueToNext && rule.forward.isEmpty && !rule.reply
            && !rule.flag && !rule.markRead && rule.flags.isEmpty
            && (rule.action == .none || (rule.action == .copy && rule.copyFolders.isEmpty))
    }

    /// The server's slot-shape rules for a rule's custom flags: fixed
    /// `cabal-flag-01..20` atoms, unique, bounded. Palette membership is
    /// deliberately NOT checked here (nor server-side at write): like a
    /// deleted destination folder, a slot that leaves the palette makes
    /// the compiler skip the rule rather than wedging the save. Shared with
    /// `FeedRulesValidator`, as the Lambda shares `_rule_flags_errors`;
    /// `list` labels the issues.
    static func ruleFlagsIssues(
        _ flags: [String], at index: Int, list: String? = nil
    ) -> [Issue] {
        if flags.count > maxRuleFlags {
            return [Issue(
                list: list, ruleIndex: index, field: "flags",
                message: "At most \(maxRuleFlags) flags per rule."
            )]
        }
        var issues: [Issue] = []
        var seen = Set<String>()
        for (position, slot) in flags.enumerated() {
            if !FlagPalette.slots.contains(slot) {
                issues.append(Issue(
                    list: list, ruleIndex: index, field: "flags[\(position)]",
                    message: "Unknown flag slot."
                ))
            } else if !seen.insert(slot).inserted {
                issues.append(Issue(
                    list: list, ruleIndex: index, field: "flags[\(position)]",
                    message: "Duplicate flag slot."
                ))
            }
        }
        return issues
    }

    /// The Lambda's `FORWARD_RE` (`^[^\s@]+@[^\s@]+\.[^\s@]+$`) plus its
    /// length and control-character checks: exactly one `@`, no whitespace,
    /// and a dot in the domain that is neither its first nor last character.
    public static func isValidForwardAddress(_ address: String) -> Bool {
        guard !address.isEmpty,
              scalarCount(address) <= maxAddressLength,
              !containsForbiddenControls(address),
              !address.contains(where: \.isWhitespace)
        else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last,
              !local.isEmpty
        else { return false }
        // The regex's domain shape (`[^\s@]+\.[^\s@]+`) reduces to: some dot
        // that is neither the domain's first nor last character.
        return domain.dropFirst().dropLast().contains(".")
    }

    // MARK: - Per-field checks

    private static func scalarIssues(_ rule: Rule, at index: Int) -> [Issue] {
        var issues: [Issue] = []
        if let nameIssue = nameIssue(rule.name, at: index) {
            issues.append(nameIssue)
        }
        if let folderMessage = folderIssue(rule.moveFolder) {
            issues.append(Issue(ruleIndex: index, field: "moveFolder", message: folderMessage))
        }
        if scalarCount(rule.replyBody) > maxReplyBodyLength
            || containsForbiddenControls(rule.replyBody, allowingNewlines: true) {
            issues.append(Issue(
                ruleIndex: index, field: "replyBody",
                message: "Must be at most \(maxReplyBodyLength) characters; newlines only."
            ))
        } else if rule.reply && rule.replyBody.isEmpty {
            issues.append(Issue(
                ruleIndex: index, field: "replyBody", message: "Required when reply is on."
            ))
        }
        return issues
    }

    /// The Lambda's name check in `_name_and_bool_errors`, which mail and
    /// feed rules share: 1 to 100 code points once trimmed, no control
    /// characters.
    static func nameIssue(_ name: String, at index: Int, list: String? = nil) -> Issue? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty || scalarCount(trimmedName) > maxNameLength
            || containsForbiddenControls(name)
        else { return nil }
        return Issue(
            list: list, ruleIndex: index, field: "name",
            message: "Must be 1-\(maxNameLength) characters, no control characters."
        )
    }

    /// The Lambda's `_condition_errors` over a rule's condition values, in
    /// order: the count cap alone when it is exceeded, else one issue per
    /// value that is empty, too long or carries a control character. Which
    /// fields a condition may name is the model's business (an unknown one
    /// keeps the rule opaque), so only the values come here; mail and feed
    /// rules share the check as the Lambda does.
    static func conditionIssues(
        _ values: [String], at index: Int, list: String? = nil
    ) -> [Issue] {
        if values.count > maxConditions {
            return [Issue(
                list: list, ruleIndex: index, field: "conditions",
                message: "At most \(maxConditions) conditions per rule."
            )]
        }
        return values.enumerated().compactMap { position, value in
            let count = scalarCount(value)
            guard count < 1 || count > maxValueLength
                || containsForbiddenControls(value)
            else { return nil }
            return Issue(
                list: list, ruleIndex: index, field: "conditions[\(position)].value",
                message: "Must be 1-\(maxValueLength) characters, no control characters."
            )
        }
    }

    private static func copyFolderIssues(_ folders: [String], at index: Int) -> [Issue] {
        if folders.count > maxCopyFolders {
            return [Issue(
                ruleIndex: index, field: "copyFolders",
                message: "At most \(maxCopyFolders) copy targets per rule."
            )]
        }
        return folders.enumerated().compactMap { position, folder in
            let message = folder.isEmpty ? "Copy target must not be empty." : folderIssue(folder)
            return message.map {
                Issue(ruleIndex: index, field: "copyFolders[\(position)]", message: $0)
            }
        }
    }

    private static func forwardIssues(_ forwards: [String], at index: Int) -> [Issue] {
        var issues: [Issue] = []
        if forwards.count > maxForwards {
            issues.append(Issue(
                ruleIndex: index, field: "forward",
                message: "At most \(maxForwards) forward addresses per rule."
            ))
        }
        issues += forwards.enumerated().compactMap { position, address in
            isValidForwardAddress(address) ? nil : Issue(
                ruleIndex: index, field: "forward[\(position)]",
                message: "Not a valid email address."
            )
        }
        return issues
    }

    /// The Lambda's `_folder_error`: empty is allowed (destination not picked
    /// yet — the compiler skips with `folder_not_set`), otherwise bounded,
    /// control-free, without procmail-meaningful characters, and a relative
    /// path with no `..`.
    static func folderIssue(_ folder: String) -> String? {
        guard !folder.isEmpty else { return nil }
        if scalarCount(folder) > maxFolderLength {
            return "Folder name exceeds \(maxFolderLength) characters."
        }
        if containsForbiddenControls(folder)
            || folder.contains(where: { "|>`".contains($0) }) {
            return "Folder name contains a forbidden character."
        }
        if folder.hasPrefix("/") || folder.contains("..") {
            return "Folder name must be a relative path without \"..\"."
        }
        return nil
    }

    /// The Lambda's `_bad_controls`: scalars below 0x20 (except `\n` when
    /// allowed) and DEL (0x7F).
    static func containsForbiddenControls(
        _ value: String, allowingNewlines: Bool = false
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            (scalar.value < 32 && !(allowingNewlines && scalar == "\n")) || scalar.value == 127
        }
    }

    /// Length as the server counts it: Python's `len()` is code points, which
    /// is `unicodeScalars`, not `String.count` grapheme clusters.
    private static func scalarCount(_ value: String) -> Int {
        value.unicodeScalars.count
    }
}
