import Foundation
import CabalmailKit

/// The plan's quick-start templates. All start disabled: each needs a user
/// decision (a destination folder, the real sender, the reply wording, the
/// word to look for) before it should act on mail or on feed items.
enum RuleTemplates {
    static func fileReceipts() -> Rule {
        Rule(
            name: "File AWS receipts",
            enabled: false,
            conditions: [Rule.Condition(field: .from, value: "aws.amazon.com")],
            action: .move
        )
    }

    static func muteNewsletter() -> Rule {
        Rule(
            name: "Mute a newsletter",
            enabled: false,
            conditions: [Rule.Condition(field: .from, value: "newsletter@example.com")],
            action: .archive,
            markRead: true
        )
    }

    static func vacationReply() -> Rule {
        Rule(
            name: "Vacation reply",
            enabled: false,
            reply: true,
            replyBody: "I'm away right now and will reply when I return."
        )
    }

    /// The feed template: flags new items whose title has a word. Disabled,
    /// like the mail templates, until the user has put in their own word
    /// (and, if they want, picked the one feed it applies to).
    static func flagMatchingItems() -> FeedRule {
        FeedRule(
            name: "Flag matching items",
            enabled: false,
            conditions: [FeedRule.Condition(field: .title, value: "keyword")],
            flag: true
        )
    }
}

/// One-line rule summary for the list rows, in the spirit of the design
/// handoff's `describeRule`.
enum RuleSummary {
    static func describe(_ rule: Rule) -> String {
        // A rule carrying a field or action this build doesn't know is
        // summarized by what it uses instead of by a guess: every other
        // phrase below would have to render a value with no meaning here
        // (#1901).
        if !rule.isEditable {
            return "Uses \(rule.unknownWireValues.joined(separator: ", ")), "
                + "which this version doesn't understand — kept unchanged"
        }
        var parts = [conditionsPhrase(rule.conditions)]
        // A continuing None rule neither files nor stops; "no filing" would
        // just be noise, so a decorate-only rule reads "flag · continue".
        if !(rule.action == .none && rule.continueToNext) {
            parts.append(actionPhrase(rule))
        }
        if rule.flag { parts.append("flag") }
        // Custom flags by count: the summary is pure (no palette access),
        // so labels can't resolve here — the editor shows them.
        if !rule.flags.isEmpty {
            parts.append(rule.flags.count == 1
                ? "1 custom flag" : "\(rule.flags.count) custom flags")
        }
        if rule.markRead { parts.append("mark read") }
        if !rule.forward.isEmpty { parts.append("forward to \(rule.forward.joined(separator: ", "))") }
        if rule.reply { parts.append("reply") }
        // "continue" last, so a spill-through rule reads as what it is:
        // "copy to Receipts · continue" (truthful Continue, Phase 1).
        if rule.continueToNext { parts.append("continue") }
        return parts.joined(separator: " · ")
    }

    private static func conditionsPhrase(_ conditions: [Rule.Condition]) -> String {
        guard let first = conditions.first else { return "Every message" }
        let phrase = "\(fieldName(first.field)) contains “\(first.value)”"
        let rest = conditions.count - 1
        return rest > 0 ? "\(phrase) + \(rest) more" : phrase
    }

    private static func actionPhrase(_ rule: Rule) -> String {
        switch rule.action {
        case .move:
            return rule.moveFolder.isEmpty
                ? "move (pick a folder)" : "move to \(rule.moveFolder)"
        case .copy:
            return rule.copyFolders.isEmpty
                ? "copy (pick folders)" : "copy to \(rule.copyFolders.joined(separator: ", "))"
        case .delete:
            return "delete"
        case .archive:
            return "archive"
        case .none:
            return "no filing"
        case .unknown(let value):
            return value
        }
    }

    private static func fieldName(_ field: Rule.Field) -> String {
        switch field {
        case .from: return "From"
        case .to: return "To"
        case .cc: return "Cc"
        case .subject: return "Subject"
        case .body: return "Body"
        case .unknown(let value): return value
        }
    }
}

/// One-line summary of a feed rule for its row. Pure, like `RuleSummary`:
/// the caller resolves the feed's title, since a rule holds only a
/// subscription id.
enum FeedRuleSummary {
    /// `feedTitle` is the title of the subscription the rule is limited to,
    /// or nil when the rule has no feed or this device doesn't know it.
    static func describe(_ rule: FeedRule, feedTitle: String?) -> String {
        // As for a mail rule: say what an unrenderable rule uses rather
        // than guess at what it means (#1901).
        if !rule.isEditable {
            return "Uses \(rule.unknownWireValues.joined(separator: ", ")), "
                + "which this version doesn't understand — kept unchanged"
        }
        var parts = [matchPhrase(rule, feedTitle: feedTitle)]
        if rule.flag { parts.append("flag") }
        // Custom flags by count, as `RuleSummary` does: no palette here.
        if !rule.flags.isEmpty {
            parts.append(rule.flags.count == 1
                ? "1 custom flag" : "\(rule.flags.count) custom flags")
        }
        if rule.markRead { parts.append("mark read") }
        // The server accepts a rule that marks nothing; the row says so
        // rather than leave an enabled rule looking as if it did something.
        if !rule.hasAction { parts.append("no action yet") }
        return parts.joined(separator: " · ")
    }

    /// Which items the rule matches: its feed, then its first text
    /// condition and a count of the rest.
    private static func matchPhrase(_ rule: FeedRule, feedTitle: String?) -> String {
        let scope = scopePhrase(rule, feedTitle: feedTitle)
        let text = rule.conditions.filter { $0.field != .feed }
        guard let first = text.first else {
            return scope.map { "Every new item in \($0)" } ?? "Every new item"
        }
        var phrase = "\(fieldName(first.field)) contains “\(first.value)”"
        if text.count > 1 { phrase += " + \(text.count - 1) more" }
        return scope.map { "\(phrase) in \($0)" } ?? phrase
    }

    private static func scopePhrase(_ rule: FeedRule, feedTitle: String?) -> String? {
        guard rule.feedSubscriptionID != nil else { return nil }
        return feedTitle ?? "one feed"
    }

    static func fieldName(_ field: FeedRule.Field) -> String {
        switch field {
        case .feed: return "Feed"
        case .title: return "Title"
        case .author: return "Author"
        case .summary: return "Summary"
        case .unknown(let value): return value
        }
    }
}
