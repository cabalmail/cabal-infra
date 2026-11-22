package com.cabalmail.kit.rules

import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.rules.RulesValidator.Issue

/**
 * Client-side mirror of the `/set_rules` Lambda's write-time validation of
 * `feedRules` (`_normalize_feed_rules` in
 * `lambda/api/set_rules/function.py`), the Kotlin sibling of the Apple
 * kit's `FeedRulesValidator`. The editor holds the debounced PUT and shows
 * the problem instead of round-tripping for a 400.
 *
 * The name, condition and flag-slot checks are [RulesValidator]'s own,
 * shared here as the Lambda shares them; the one check a feed rule adds is
 * the single `feed` condition. Every issue carries [LIST], as the Lambda's
 * entries for a feed rule do.
 *
 * What is deliberately not mirrored:
 * - Whether a `feed` condition names a subscription the user still has, and
 *   whether a slot is still in the flag list. The server checks neither at
 *   save time; the fetcher decides when an item arrives.
 * - The server's byte cap on the stored list (`MAX_FEED_RULES_BYTES`). The
 *   two sides serialize differently, so a mirror would not agree at the
 *   boundary; the server's 400 shows as a failed save.
 * - A rule with no action. The server accepts it and it does nothing; the
 *   editor says so ([FeedRule.hasAction]) rather than hold the save, since
 *   a new blank rule has none.
 */
object FeedRulesValidator {
    const val MAX_RULES = 100

    /** The `list` every issue here carries. */
    const val LIST = "feedRules"

    /** Validates the whole list; empty means the server will accept it verbatim. */
    fun validate(rules: List<FeedRule>): List<Issue> =
        buildList {
            if (rules.size > MAX_RULES) {
                add(Issue(ruleIndex = null, field = LIST, message = "At most $MAX_RULES feed rules.", list = LIST))
            }
            rules.forEachIndexed { index, rule -> addAll(validate(rule, index)) }
        }

    /**
     * Validates one feed rule; [index] only labels the returned issues.
     *
     * A rule this build cannot render ([FeedRule.isEditable] false) is never
     * an issue: it is saved back as it was, and flagging it would hold the
     * whole set's save hostage to a rule nothing here can fix.
     */
    fun validate(
        rule: FeedRule,
        index: Int = 0,
    ): List<Issue> {
        if (!rule.isEditable) {
            return emptyList()
        }
        return listOfNotNull(RulesValidator.nameIssue(rule.name, index, LIST)) +
            conditionIssues(rule.conditions, index) +
            RulesValidator.ruleFlagsIssues(rule.flags, index, LIST)
    }

    /**
     * The Lambda's `_feed_condition_errors`: a mail rule's shape checks,
     * then, only when those pass, at most one `feed` condition. Conditions
     * are ANDed and `feed` names one subscription exactly, so two of them
     * could never both hold.
     */
    private fun conditionIssues(
        conditions: List<FeedRuleCondition>,
        index: Int,
    ): List<Issue> {
        val shape = RulesValidator.conditionIssues(conditions.map { it.value }, index, LIST)
        if (shape.isNotEmpty() || conditions.count { it.field == FeedRuleField.FEED } <= 1) {
            return shape
        }
        return listOf(Issue(index, "conditions", "At most one feed condition per rule.", LIST))
    }
}
