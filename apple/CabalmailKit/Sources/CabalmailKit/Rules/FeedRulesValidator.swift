import Foundation

/// Client-side mirror of the `/set_rules` Lambda's write-time validation of
/// `feedRules` (`_normalize_feed_rules` in
/// `lambda/api/set_rules/function.py`), so the editors can flag a problem
/// inline before a PUT instead of round-tripping for a 400. Keep the two in
/// lockstep, as `RulesValidator` is for mail rules: the name, condition and
/// flag-slot checks are that validator's own, shared here as the Lambda
/// shares them, and the one check a feed rule adds is the single `feed`
/// condition.
///
/// What is deliberately not mirrored:
/// - Whether a `feed` condition names a subscription the user still has, and
///   whether a slot is still in the flag list. The server does not check
///   either at save time; the fetcher decides when an item arrives.
/// - The server's byte cap on the stored list (`MAX_FEED_RULES_BYTES`). The
///   two sides serialize differently, so a mirror would not agree at the
///   boundary; the server's 400 surfaces as a failed save.
/// - A rule with no action. The server accepts it and it does nothing; the
///   editors say so (`FeedRule.hasAction`) rather than hold the save, since
///   a new blank rule has none.
public enum FeedRulesValidator {
    public static let maxRules = 100
    /// The `list` every issue here carries, as the Lambda's entries do.
    public static let listName = "feedRules"

    /// Validates the whole list; empty means the server will accept it
    /// verbatim.
    public static func validate(_ rules: [FeedRule]) -> [RulesValidator.Issue] {
        var issues: [RulesValidator.Issue] = []
        if rules.count > maxRules {
            issues.append(RulesValidator.Issue(
                list: listName, ruleIndex: nil, field: listName,
                message: "At most \(maxRules) feed rules."
            ))
        }
        for (index, rule) in rules.enumerated() {
            issues += validate(rule, at: index)
        }
        return issues
    }

    /// Validates one feed rule. `index` only labels the returned issues.
    ///
    /// A rule this build can't render (`FeedRule.isEditable` false) is never
    /// an issue, for the reason an opaque mail rule is not: it is saved back
    /// unchanged, and flagging it would hold the whole set's save hostage to
    /// a rule nothing local can fix (#1901).
    public static func validate(_ rule: FeedRule, at index: Int = 0) -> [RulesValidator.Issue] {
        guard rule.isEditable else { return [] }
        var issues: [RulesValidator.Issue] = []
        if let nameIssue = RulesValidator.nameIssue(rule.name, at: index, list: listName) {
            issues.append(nameIssue)
        }
        issues += conditionIssues(rule.conditions, at: index)
        issues += RulesValidator.ruleFlagsIssues(rule.flags, at: index, list: listName)
        return issues
    }

    /// The Lambda's `_feed_condition_errors`: a mail rule's shape checks,
    /// then, only when those pass, at most one `feed` condition. Conditions
    /// are ANDed and `feed` names one subscription exactly, so two of them
    /// could never both hold.
    private static func conditionIssues(
        _ conditions: [FeedRule.Condition], at index: Int
    ) -> [RulesValidator.Issue] {
        let shape = RulesValidator.conditionIssues(
            conditions.map(\.value), at: index, list: listName
        )
        guard shape.isEmpty else { return shape }
        guard conditions.filter({ $0.field == .feed }).count > 1 else { return [] }
        return [RulesValidator.Issue(
            list: listName, ruleIndex: index, field: "conditions",
            message: "At most one feed condition per rule."
        )]
    }
}
