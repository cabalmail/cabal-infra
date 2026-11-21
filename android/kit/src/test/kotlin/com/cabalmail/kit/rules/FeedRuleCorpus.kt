package com.cabalmail.kit.rules

import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.settings.FlagPalette

/**
 * Feed rule lists at and one step past each limit `_normalize_feed_rules`
 * holds (`lambda/api/set_rules/function.py`), with what the server does to
 * each. [FeedRulesValidatorTest] holds the validator to it, and can write
 * it out as request bodies so the same cases can be put to a real
 * `/set_rules` (see `writes the corpus out when asked`).
 */
object FeedRuleCorpus {
    /**
     * [refusedOn] is null for a list the server stores, else the `field` of
     * the first error it answers (`feedRules` standing for the list-level
     * cap, which the server answers as a plain `Error`).
     */
    data class Case(
        val name: String,
        val rules: List<FeedRule>,
        val refusedOn: String?,
    )

    private fun text(
        value: String,
        field: FeedRuleField = FeedRuleField.TITLE,
    ) = FeedRuleCondition(field, value)

    private fun rule(
        name: String = "Releases",
        conditions: List<FeedRuleCondition> = listOf(text("release")),
        flags: List<String> = emptyList(),
    ) = FeedRule(name = name, conditions = conditions, flag = true, flags = flags)

    /** A rule at every per-rule limit at once. */
    private val atEveryLimit =
        FeedRule(
            name = "n".repeat(100),
            enabled = true,
            conditions =
                listOf(FeedRuleCondition(FeedRuleField.FEED, "f".repeat(500))) +
                    List(9) { index -> text("v".repeat(500), FeedRuleField.TEXT[index % 3]) },
            flag = true,
            flags = FlagPalette.SLOTS,
            markRead = true,
        )

    val cases: List<Case> =
        listOf(
            Case("a plain rule", listOf(rule()), null),
            Case("a rule at every limit", listOf(atEveryLimit), null),
            Case(
                "a blank rule, with no condition and no action",
                listOf(FeedRule(name = "New rule", enabled = false)),
                null,
            ),
            // Lengths are counted in code points, as Python's len() counts
            // them: 100 of these are 200 UTF-16 units.
            Case("a name of 100 astral characters", listOf(rule(name = "📫".repeat(100))), null),
            Case("an empty list", emptyList(), null),
            Case("100 rules", List(100) { rule(name = "Rule $it") }, null),
            Case("101 rules", List(101) { rule(name = "Rule $it") }, "feedRules"),
            Case("an empty name", listOf(rule(name = "")), "name"),
            Case("a name of spaces", listOf(rule(name = "   ")), "name"),
            Case("a name of 101", listOf(rule(name = "n".repeat(101))), "name"),
            Case("a tab in a name", listOf(rule(name = "tab\tname")), "name"),
            Case("eleven conditions", listOf(rule(conditions = List(11) { text("v$it") })), "conditions"),
            Case("an empty value", listOf(rule(conditions = listOf(text("")))), "conditions[0].value"),
            Case("a value of 501", listOf(rule(conditions = listOf(text("v".repeat(501))))), "conditions[0].value"),
            Case(
                "a control character in a value",
                listOf(rule(conditions = listOf(text("nul\u0000byte")))),
                "conditions[0].value",
            ),
            Case(
                "two feed conditions",
                listOf(
                    rule(
                        conditions =
                            listOf(
                                FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                                FeedRuleCondition(FeedRuleField.FEED, "sub-2"),
                            ),
                    ),
                ),
                "conditions",
            ),
            Case("twenty-one flags", listOf(rule(flags = FlagPalette.SLOTS + FlagPalette.SLOTS.first())), "flags"),
            Case("a slot past the last", listOf(rule(flags = listOf("cabal-flag-21"))), "flags[0]"),
            Case(
                "the built-in flag's atom as a slot",
                listOf(rule(flags = listOf(FlagPalette.SYSTEM_SLOT))),
                "flags[0]",
            ),
            Case("a slot twice", listOf(rule(flags = listOf("cabal-flag-02", "cabal-flag-02"))), "flags[1]"),
            Case("a bad rule after a good one", listOf(rule(), rule(name = "")), "name"),
        )
}
