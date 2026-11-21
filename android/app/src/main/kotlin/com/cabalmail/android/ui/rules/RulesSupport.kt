package com.cabalmail.android.ui.rules

import androidx.annotation.StringRes
import com.cabalmail.android.R
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField

/**
 * The plan's quick-start templates. All start disabled: each needs a user
 * decision (a destination folder, the real sender, the reply wording, the
 * word to look for) before it should act on mail or on feed items — and
 * the placeholder values keep the set valid, so a fresh template never
 * wedges the validation-gated auto-save.
 */
object RuleTemplates {
    fun fileReceipts(): Rule =
        Rule(
            name = "File AWS receipts",
            enabled = false,
            conditions = listOf(RuleCondition(RuleField.FROM, "aws.amazon.com")),
            action = RuleAction.MOVE,
        )

    fun muteNewsletter(): Rule =
        Rule(
            name = "Mute a newsletter",
            enabled = false,
            conditions = listOf(RuleCondition(RuleField.FROM, "newsletter@example.com")),
            action = RuleAction.ARCHIVE,
            markRead = true,
        )

    fun vacationReply(): Rule =
        Rule(
            name = "Vacation reply",
            enabled = false,
            reply = true,
            replyBody = "I'm away right now and will reply when I return.",
        )

    /**
     * The feed template: flags new items whose title has a word. Disabled,
     * like the mail templates, until the user has put in their own word
     * (and, if they want, picked the one feed it applies to).
     */
    fun flagMatchingItems(): FeedRule =
        FeedRule(
            name = "Flag matching items",
            enabled = false,
            conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, "keyword")),
            flag = true,
        )
}

/**
 * One-line rule summary for the list rows — the same shape the Apple
 * client's `RuleSummary` renders. Pure so it unit-tests without Compose.
 */
fun describeRule(rule: Rule): String {
    val parts = mutableListOf(conditionsPhrase(rule.conditions))
    // A continuing None rule neither files nor stops; "no filing" would
    // just be noise, so a decorate-only rule reads "flag · continue".
    if (!(rule.action == RuleAction.NONE && rule.continueToNext)) {
        parts += actionPhrase(rule)
    }
    if (rule.flag) parts += "flag"
    // Custom flags by count: the summary is pure (no palette access), so
    // labels can't resolve here — the editor shows them.
    if (rule.flags.isNotEmpty()) {
        parts += if (rule.flags.size == 1) "1 custom flag" else "${rule.flags.size} custom flags"
    }
    if (rule.markRead) parts += "mark read"
    if (rule.forward.isNotEmpty()) parts += "forward to ${rule.forward.joinToString(", ")}"
    if (rule.reply) parts += "reply"
    // "continue" last, so a spill-through rule reads as what it is:
    // "copy to Receipts · continue" (truthful Continue, Phase 1).
    if (rule.continueToNext) parts += "continue"
    return parts.joinToString(" · ")
}

private fun conditionsPhrase(conditions: List<RuleCondition>): String {
    val first = conditions.firstOrNull() ?: return "Every message"
    val phrase = "${fieldName(first.field)} contains “${first.value}”"
    val rest = conditions.size - 1
    return if (rest > 0) "$phrase + $rest more" else phrase
}

private fun actionPhrase(rule: Rule): String =
    when (rule.action) {
        RuleAction.MOVE ->
            if (rule.moveFolder.isEmpty()) "move (pick a folder)" else "move to ${rule.moveFolder}"
        RuleAction.COPY ->
            if (rule.copyFolders.isEmpty()) "copy (pick folders)" else "copy to ${rule.copyFolders.joinToString(", ")}"
        RuleAction.DELETE -> "delete"
        RuleAction.ARCHIVE -> "archive"
        RuleAction.NONE -> "no filing"
    }

private fun fieldName(field: RuleField): String =
    when (field) {
        RuleField.FROM -> "From"
        RuleField.TO -> "To"
        RuleField.CC -> "Cc"
        RuleField.SUBJECT -> "Subject"
        RuleField.BODY -> "Body"
    }

/**
 * Whether a condition on this field takes the email keyboard. From, To and
 * Cc hold addresses, so most values are a domain or an address fragment;
 * the email keyboard still has a space bar for a display name, which the
 * match also searches (#2022). Subject and Body are free text.
 */
val RuleField.holdsAddresses: Boolean
    get() =
        when (this) {
            RuleField.FROM, RuleField.TO, RuleField.CC -> true
            RuleField.SUBJECT, RuleField.BODY -> false
        }

/**
 * One-line summary of a feed rule for its row, the same shape the Apple
 * client's `FeedRuleSummary` renders. Pure, like [describeRule]: the caller
 * resolves [feedTitle], the title of the subscription the rule is limited
 * to, since a rule holds only its id. Null when the rule has no feed or
 * this device does not know it.
 */
fun describeFeedRule(
    rule: FeedRule,
    feedTitle: String?,
): String {
    if (!rule.isEditable) {
        return "Uses ${rule.unknownFields.joinToString(", ")}, " +
            "which this version doesn't understand — kept unchanged"
    }
    val parts = mutableListOf(feedMatchPhrase(rule, feedTitle))
    if (rule.flag) parts += "flag"
    if (rule.flags.isNotEmpty()) {
        parts += if (rule.flags.size == 1) "1 custom flag" else "${rule.flags.size} custom flags"
    }
    if (rule.markRead) parts += "mark read"
    // The server stores a rule that marks nothing, and it then does
    // nothing; the row says so rather than reading as a working rule.
    if (!rule.hasAction) parts += "no action yet"
    return parts.joinToString(" · ")
}

/** Which items the rule matches: its first text condition, then its feed. */
private fun feedMatchPhrase(
    rule: FeedRule,
    feedTitle: String?,
): String {
    val scope = if (rule.feedSubscriptionId == null) null else feedTitle ?: "one feed"
    val text = rule.textConditions
    val first = text.firstOrNull() ?: return if (scope == null) "Every new item" else "Every new item in $scope"
    var phrase = "${feedFieldName(first.field)} contains “${first.value}”"
    if (text.size > 1) phrase += " + ${text.size - 1} more"
    return if (scope == null) phrase else "$phrase in $scope"
}

private fun feedFieldName(field: FeedRuleField): String =
    when (field) {
        FeedRuleField.FEED -> "Feed"
        FeedRuleField.TITLE -> "Title"
        FeedRuleField.AUTHOR -> "Author"
        FeedRuleField.SUMMARY -> "Summary"
        else -> field.wire
    }

// The feed rule editor's hints, as plain functions of the rule so what each
// says in each state is tested without drawing the form.

/**
 * The hint under the Feed picker. [subscriptions] is null until the user's
 * feeds have loaded on this device, and a stored feed is not called
 * unsubscribed on that account alone.
 */
@StringRes
fun feedScopeHint(
    rule: FeedRule,
    subscriptions: List<RssSubscription>?,
): Int {
    val stored = rule.feedSubscriptionId ?: return R.string.rules_feed_all_hint
    return if (subscriptions == null || subscriptions.any { it.subscriptionId == stored }) {
        R.string.rules_feed_one_hint
    } else {
        R.string.rules_feed_unsubscribed_hint
    }
}

/**
 * How the Feed picker names a stored feed that is not among the listed
 * subscriptions, or null when it is listed (or the rule has no feed). The
 * feed stays selected under this label until the user picks another:
 * resetting it to All feeds would silently widen the rule.
 */
@StringRes
fun unlistedFeedLabel(
    rule: FeedRule,
    subscriptions: List<RssSubscription>?,
): Int? {
    val stored = rule.feedSubscriptionId ?: return null
    return when {
        subscriptions == null -> R.string.rules_feed_one
        subscriptions.none { it.subscriptionId == stored } -> R.string.rules_feed_unsubscribed
        else -> null
    }
}

@StringRes
fun feedConditionsHint(rule: FeedRule): Int =
    when {
        rule.textConditions.isNotEmpty() -> R.string.rules_feed_conditions_hint
        rule.feedSubscriptionId == null -> R.string.rules_feed_conditions_empty_all_hint
        else -> R.string.rules_feed_conditions_empty_one_hint
    }

/**
 * The hint under the actions. [hasDeletedFlag] is whether the rule sets a
 * flag no longer in Settings > Flags: the fetcher skips such a rule whole,
 * which matters more than anything else the hint could say.
 */
@StringRes
fun feedActionsHint(
    rule: FeedRule,
    hasDeletedFlag: Boolean,
): Int =
    when {
        hasDeletedFlag -> R.string.rules_feed_deleted_flag_hint
        !rule.hasAction -> R.string.rules_feed_no_action_hint
        else -> R.string.rules_feed_actions_hint
    }
