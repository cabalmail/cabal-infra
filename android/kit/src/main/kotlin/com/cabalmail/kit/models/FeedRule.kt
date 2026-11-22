package com.cabalmail.kit.models

import kotlinx.serialization.Serializable

// Wire models for feed rules: the `feedRules` list `/get_rules` answers and
// `/set_rules` accepts beside the mail rules, under the same version
// (`lambda/api/set_rules/function.py`), and that the feed fetcher applies
// to each item it first inserts (`lambda/api/_shared/rss_rules.py`). See
// `docs/mail-rules.md`, "Feed rules". The Kotlin sibling of the Apple kit's
// `FeedRule`.

/**
 * A feed rule condition's field, held as its wire value.
 *
 * Not an enum, on purpose. The two rule lists arrive in one reply, and an
 * enum fails the decode on a value it does not know: a field a later server
 * adds would then take the mail rules down with the feed rules ("Could not
 * load rules"). A field this build does not know decodes like any other and
 * makes its rule read-only ([FeedRule.isEditable]) instead.
 */
@Serializable
@JvmInline
value class FeedRuleField(
    val wire: String,
) {
    /** Whether this build knows the field. */
    val isKnown: Boolean get() = this in KNOWN

    companion object {
        /**
         * Not a text match: it holds one subscription id and matches it
         * exactly, at most one to a rule. The editor shows it as the rule's
         * feed, not as a condition row ([FeedRule.feedSubscriptionId]).
         */
        val FEED = FeedRuleField("feed")
        val TITLE = FeedRuleField("title")
        val AUTHOR = FeedRuleField("author")

        /** Searches the item's summary and the text of its body. */
        val SUMMARY = FeedRuleField("summary")

        /** The server's `FEED_FIELDS`. */
        val KNOWN: List<FeedRuleField> = listOf(FEED, TITLE, AUTHOR, SUMMARY)

        /** The fields a "contains" condition row offers: every known one but [FEED]. */
        val TEXT: List<FeedRuleField> = listOf(TITLE, AUTHOR, SUMMARY)
    }
}

/**
 * One trigger clause; a rule's conditions are ANDed. For the text fields the
 * value is a case-insensitive "contains"; for [FeedRuleField.FEED] it is a
 * subscription id. An empty list matches every new item in every feed.
 */
@Serializable
data class FeedRuleCondition(
    val field: FeedRuleField = FeedRuleField.TITLE,
    val value: String = "",
)

/**
 * One user-defined feed rule: a mail rule with the filing taken out. It has
 * conditions and the three marks, and no destination, forward, reply or
 * "continue". Nothing is filed, so every matching enabled rule applies and
 * the list's order is only how it is shown.
 *
 * [id] is in a mail rule's format and unique across both lists; new local
 * rules mint one via [mintRuleId], which the Lambda keeps.
 *
 * Every key is always encoded: any server that accepts `feedRules` knows
 * all seven, so none is held back the way [Rule] holds back an empty
 * `flags`.
 */
@Serializable
data class FeedRule(
    val id: String = mintRuleId(),
    val name: String = "",
    val enabled: Boolean = true,
    val conditions: List<FeedRuleCondition> = emptyList(),
    /** Sets the built-in flag (the item's `is_favorite`). */
    val flag: Boolean = false,
    /**
     * Custom-flag slot atoms the rule sets. A slot no longer in the
     * subscriber's flag list makes the fetcher skip the whole rule.
     */
    val flags: List<String> = emptyList(),
    val markRead: Boolean = false,
) {
    /** The condition fields this build does not know, in wire order. */
    val unknownFields: List<String>
        get() = conditions.filterNot { it.field.isKnown }.map { it.field.wire }

    /**
     * Whether the editors may change this rule. False for a rule carrying a
     * condition field this build does not know: it is listed, can be moved
     * and deleted, and is saved back as it was decoded. A rewritten copy
     * would drop whatever its writer meant by the field.
     */
    val isEditable: Boolean get() = conditions.all { it.field.isKnown }

    /**
     * Whether the rule marks anything. One that does not is accepted by the
     * server and does nothing when it matches.
     */
    val hasAction: Boolean get() = flag || markRead || flags.isNotEmpty()

    /**
     * The subscription the rule is limited to, or null when it covers every
     * feed. On the wire this is the rule's one `feed` condition.
     */
    val feedSubscriptionId: String?
        get() = conditions.firstOrNull { it.field == FeedRuleField.FEED }?.value

    /** The conditions the editor shows as rows: all but the `feed` one. */
    val textConditions: List<FeedRuleCondition>
        get() = conditions.filter { it.field != FeedRuleField.FEED }

    /**
     * The rule limited to [subscriptionId], or to no feed for null. The
     * `feed` condition is rewritten where it stands, added at the head of
     * the list, or removed; the server refuses a second, so every `feed`
     * condition past the first goes too.
     */
    fun withFeed(subscriptionId: String?): FeedRule {
        val first = conditions.indexOfFirst { it.field == FeedRuleField.FEED }
        val kept =
            conditions.filterIndexed { index, condition ->
                condition.field != FeedRuleField.FEED || (subscriptionId != null && index == first)
            }
        return when {
            subscriptionId == null -> copy(conditions = kept)
            first < 0 -> copy(conditions = listOf(FeedRuleCondition(FeedRuleField.FEED, subscriptionId)) + kept)
            else ->
                copy(
                    conditions =
                        kept.map { condition ->
                            if (condition.field ==
                                FeedRuleField.FEED
                            ) {
                                condition.copy(value = subscriptionId)
                            } else {
                                condition
                            }
                        },
                )
        }
    }

    /**
     * The rule with its text conditions replaced, the `feed` condition
     * staying where it is: at the head, where [withFeed] puts it, or
     * wherever another client stored it relative to the rest.
     */
    fun withTextConditions(text: List<FeedRuleCondition>): FeedRule {
        val replacements = text.iterator()
        val merged =
            conditions.mapNotNull { condition ->
                when {
                    condition.field == FeedRuleField.FEED -> condition
                    replacements.hasNext() -> replacements.next()
                    else -> null
                }
            }
        return copy(conditions = merged + replacements.asSequence().toList())
    }
}
