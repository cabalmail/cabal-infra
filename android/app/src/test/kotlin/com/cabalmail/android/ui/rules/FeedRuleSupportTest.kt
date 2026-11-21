package com.cabalmail.android.ui.rules

import com.cabalmail.android.R
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.rules.FeedRulesValidator
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What the Rules pane says about a feed rule: its row's summary, the
 * template, the editor's hints in each state, and the flag toggles.
 */
class FeedRuleSupportTest {
    private fun title(word: String) = FeedRuleCondition(FeedRuleField.TITLE, word)

    private val subscribed =
        listOf(RssSubscription(subscriptionId = "sub-1", feedId = "f1", customTitle = "Kotlin Blog"))

    // ------------------------------------------------------------- summary

    @Test
    fun `summary reads the first condition and the marks`() {
        val rule = FeedRule(conditions = listOf(title("release")), flag = true, markRead = true)

        assertEquals("Title contains “release” · flag · mark read", describeFeedRule(rule, null))
    }

    @Test
    fun `summary counts further conditions and custom flags`() {
        val rule =
            FeedRule(
                conditions = listOf(FeedRuleCondition(FeedRuleField.AUTHOR, "ada"), title("x"), title("y")),
                flags = listOf("cabal-flag-01", "cabal-flag-02"),
            )

        assertEquals("Author contains “ada” + 2 more · 2 custom flags", describeFeedRule(rule, null))
        assertEquals(
            "Summary contains “z” · 1 custom flag",
            describeFeedRule(
                FeedRule(
                    conditions = listOf(FeedRuleCondition(FeedRuleField.SUMMARY, "z")),
                    flags = listOf("cabal-flag-01"),
                ),
                null,
            ),
        )
    }

    @Test
    fun `summary names the rule's feed, and does not count it as a condition`() {
        val rule = FeedRule(conditions = listOf(title("release")), flag = true).withFeed("sub-1")

        assertEquals("Title contains “release” in Kotlin Blog · flag", describeFeedRule(rule, "Kotlin Blog"))
        // A feed this device cannot name is still said to be one feed.
        assertEquals("Title contains “release” in one feed · flag", describeFeedRule(rule, null))
    }

    @Test
    fun `summary of a rule with no text condition says every new item`() {
        assertEquals("Every new item · flag", describeFeedRule(FeedRule(flag = true), null))
        assertEquals(
            "Every new item in Kotlin Blog · mark read",
            describeFeedRule(FeedRule(markRead = true).withFeed("sub-1"), "Kotlin Blog"),
        )
    }

    @Test
    fun `summary says when a rule does nothing yet`() {
        assertEquals(
            "Title contains “x” · no action yet",
            describeFeedRule(FeedRule(conditions = listOf(title("x"))), null),
        )
    }

    @Test
    fun `summary of a rule this build cannot render names what it uses`() {
        val rule =
            FeedRule(
                conditions = listOf(title("x"), FeedRuleCondition(FeedRuleField("category"), "news")),
                flag = true,
            )

        assertEquals(
            "Uses category, which this version doesn't understand — kept unchanged",
            describeFeedRule(rule, null),
        )
    }

    // ------------------------------------------------------------ template

    @Test
    fun `the feed template is off, valid, and flags by a title word`() {
        val template = RuleTemplates.flagMatchingItems()

        assertFalse(template.enabled)
        assertTrue(template.flag)
        assertEquals(listOf(title("keyword")), template.conditions)
        assertNull(template.feedSubscriptionId)
        // A fresh template must never wedge the validation-gated save.
        assertTrue(FeedRulesValidator.validate(listOf(template)).isEmpty())
    }

    // --------------------------------------------------------------- hints

    @Test
    fun `scope hint and label follow the rule's feed and what this device knows`() {
        val all = FeedRule()
        val listed = FeedRule().withFeed("sub-1")
        val gone = FeedRule().withFeed("sub-9")

        assertEquals(R.string.rules_feed_all_hint, feedScopeHint(all, subscribed))
        assertNull(unlistedFeedLabel(all, subscribed))

        assertEquals(R.string.rules_feed_one_hint, feedScopeHint(listed, subscribed))
        assertNull(unlistedFeedLabel(listed, subscribed))

        assertEquals(R.string.rules_feed_unsubscribed_hint, feedScopeHint(gone, subscribed))
        assertEquals(R.string.rules_feed_unsubscribed, unlistedFeedLabel(gone, subscribed))
        // A user with no subscriptions at all has unsubscribed from it too.
        assertEquals(R.string.rules_feed_unsubscribed_hint, feedScopeHint(gone, emptyList()))
    }

    @Test
    fun `a feed is not called unsubscribed before the subscriptions have loaded`() {
        val rule = FeedRule().withFeed("sub-1")

        assertEquals(R.string.rules_feed_one_hint, feedScopeHint(rule, null))
        assertEquals(R.string.rules_feed_one, unlistedFeedLabel(rule, null))
    }

    @Test
    fun `conditions hint`() {
        assertEquals(R.string.rules_feed_conditions_empty_all_hint, feedConditionsHint(FeedRule()))
        // The feed is the rule's scope, not one of its conditions.
        assertEquals(R.string.rules_feed_conditions_empty_one_hint, feedConditionsHint(FeedRule().withFeed("sub-1")))
        assertEquals(R.string.rules_feed_conditions_hint, feedConditionsHint(FeedRule(conditions = listOf(title("x")))))
    }

    @Test
    fun `actions hint puts a deleted flag first, then a rule that does nothing`() {
        val acting = FeedRule(flag = true)

        assertEquals(R.string.rules_feed_actions_hint, feedActionsHint(acting, hasDeletedFlag = false))
        assertEquals(R.string.rules_feed_no_action_hint, feedActionsHint(FeedRule(), hasDeletedFlag = false))
        assertEquals(R.string.rules_feed_deleted_flag_hint, feedActionsHint(acting, hasDeletedFlag = true))
    }

    // --------------------------------------------------------------- flags

    private val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")

    @Test
    fun `the flag toggles read a feed rule's two flag fields`() {
        val rule = FeedRule(flag = true, flags = listOf("cabal-flag-01"))

        assertEquals(
            listOf(
                RuleFlagRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = true),
                RuleFlagRow("cabal-flag-01", "Urgent", "red", isOn = true),
            ),
            ruleFlagRows(listOf(urgent), rule.flag, rule.flags),
        )
    }

    @Test
    fun `toggling the built-in flag writes flag, and any other slot writes flags`() {
        val rule = FeedRule()

        assertEquals(rule.copy(flag = true), rule.settingFlag(FlagPalette.SYSTEM_SLOT, true))
        // The built-in flag's atom never enters `flags`, which the server refuses.
        assertTrue(rule.settingFlag(FlagPalette.SYSTEM_SLOT, true).flags.isEmpty())
        val tagged = rule.settingFlag("cabal-flag-01", true)
        assertEquals(listOf("cabal-flag-01"), tagged.flags)
        assertEquals(tagged, tagged.settingFlag("cabal-flag-01", true))
        assertEquals(rule, tagged.settingFlag("cabal-flag-01", false))
    }

    @Test
    fun `a slot whose flag was deleted is a stray, with a toggle to clear it`() {
        val rule = FeedRule(flags = listOf("cabal-flag-01", "cabal-flag-07"))

        assertEquals(listOf("cabal-flag-07"), strayFlagSlots(listOf(urgent), rule.flags))
        assertEquals(
            RuleFlagRow("cabal-flag-07", label = "cabal-flag-07", color = "", isOn = true),
            ruleFlagRows(listOf(urgent), rule.flag, rule.flags).last(),
        )
        assertTrue(strayFlagSlots(listOf(urgent), listOf("cabal-flag-01")).isEmpty())
    }

    // ------------------------------------------------------------ keyboard

    @Test
    fun `a feed condition's value edits as free text nothing rewrites`() {
        // The same form the mail editor gives Subject and Body.
        assertEquals(
            ruleConditionKeyboardOptions(com.cabalmail.kit.models.RuleField.SUBJECT),
            ruleConditionKeyboardOptions(holdsAddresses = false),
        )
    }
}
