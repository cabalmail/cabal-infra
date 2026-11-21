package com.cabalmail.kit.models

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Encode/decode coverage for [FeedRule] against the wire shape `/get_rules`
 * and `/set_rules` speak for `feedRules` (`lambda/api/set_rules/
 * function.py`: `FEED_DEFAULTS` is the canonical key set and `FEED_FIELDS`
 * the condition fields; `docs/mail-rules.md`, "On the wire", is the
 * documented example decoded below).
 */
class FeedRuleModelsTest {
    // The client's read config (unknown keys tolerated)...
    private val json = Json { ignoreUnknownKeys = true }

    // ...and its request-body config (defaults always on the wire).
    private val bodyJson =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }

    /** The example in `docs/mail-rules.md`, as `/get_rules` answers it. */
    private val documentedReply =
        """
        {"rules": [],
         "feedRules": [
           {"id": "r-0123456789ab", "name": "Releases", "enabled": true,
            "conditions": [{"field": "feed", "value": "sub-1"}, {"field": "title", "value": "release"}],
            "flag": false, "flags": ["cabal-flag-03"], "markRead": false}],
         "version": 4, "updatedAt": "2026-11-19T12:00:00+00:00"}
        """.trimIndent()

    private val documentedRule =
        FeedRule(
            id = "r-0123456789ab",
            name = "Releases",
            enabled = true,
            conditions =
                listOf(
                    FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                    FeedRuleCondition(FeedRuleField.TITLE, "release"),
                ),
            flag = false,
            flags = listOf("cabal-flag-03"),
            markRead = false,
        )

    @Test
    fun `decodes the documented reply`() {
        val ruleSet = json.decodeFromString<RuleSet>(documentedReply)

        assertEquals(listOf(documentedRule), ruleSet.feedRules)
        assertTrue(ruleSet.rules.isEmpty())
        assertEquals(4, ruleSet.version)
    }

    @Test
    fun `a reply with no feedRules key reads as no feed rules`() {
        // What a server from before feed rules answers, and a rule-less user.
        assertTrue(json.decodeFromString<RuleSet>("""{"rules": [], "version": 0}""").feedRules.isEmpty())
        assertTrue(json.decodeFromString<RuleSet>("{}").feedRules.isEmpty())
    }

    @Test
    fun `an encoded rule carries exactly the server's seven keys`() {
        // `_normalize_feed_rules` refuses any key outside FEED_DEFAULTS and
        // `id`, and the row is replaced whole: a key too many is a 400, a
        // key too few reads back as its default.
        val encoded = bodyJson.parseToJsonElement(bodyJson.encodeToString(FeedRule(name = "n"))).jsonObject

        assertEquals(setOf("id", "name", "enabled", "conditions", "flag", "flags", "markRead"), encoded.keys)
        // An empty flag list rides, unlike a mail rule's: every server that
        // accepts `feedRules` knows the key.
        assertTrue(encoded["flags"]!!.jsonArray.isEmpty())
    }

    @Test
    fun `a condition encodes exactly field and value, the field as its wire word`() {
        val rule = FeedRule(conditions = FeedRuleField.KNOWN.map { FeedRuleCondition(it, "x") })

        val conditions = bodyJson.parseToJsonElement(bodyJson.encodeToString(rule)).jsonObject["conditions"]!!.jsonArray

        assertEquals(
            listOf("feed", "title", "author", "summary"),
            conditions.map {
                it.jsonObject["field"].toString().trim('"')
            },
        )
        conditions.forEach { assertEquals(setOf("field", "value"), it.jsonObject.keys) }
    }

    @Test
    fun `the documented rule encodes to the documented shape`() {
        val wire = json.parseToJsonElement(documentedReply).jsonObject["feedRules"]!!.jsonArray[0]

        assertEquals(wire, bodyJson.parseToJsonElement(bodyJson.encodeToString(documentedRule)))
    }

    @Test
    fun `round-trips every field and action`() {
        for (field in FeedRuleField.KNOWN) {
            val original =
                FeedRule(
                    name = field.wire,
                    enabled = false,
                    conditions = listOf(FeedRuleCondition(field, "x")),
                    flag = true,
                    flags = listOf("cabal-flag-01", "cabal-flag-20"),
                    markRead = true,
                )

            assertEquals(original, json.decodeFromString<FeedRule>(bodyJson.encodeToString(original)))
        }
    }

    @Test
    fun `missing keys decode as the lambda defaults`() {
        val rule = json.decodeFromString<FeedRule>("{}")

        assertEquals("", rule.name)
        assertTrue(rule.enabled)
        assertTrue(rule.conditions.isEmpty())
        assertFalse(rule.flag)
        assertTrue(rule.flags.isEmpty())
        assertFalse(rule.markRead)
        assertTrue(rule.id.startsWith("r-"))
    }

    @Test
    fun `a field this build does not know decodes, and keeps the mail rules readable`() {
        // The two lists are one reply. A strict field here would fail the
        // whole decode and take the mail rules with it.
        val reply =
            """
            {"rules": [{"id": "r-aaaaaaaaaaaa", "name": "Mail"}],
             "feedRules": [{"id": "r-bbbbbbbbbbbb", "name": "Later",
               "conditions": [{"field": "title", "value": "a"}, {"field": "category", "value": "b"}],
               "flag": true}],
             "version": 2}
            """.trimIndent()

        val ruleSet = json.decodeFromString<RuleSet>(reply)

        assertEquals(listOf("Mail"), ruleSet.rules.map { it.name })
        val rule = ruleSet.feedRules.single()
        assertFalse(rule.isEditable)
        assertEquals(listOf("category"), rule.unknownFields)
        // Saved back as it was: the unknown field goes out under its word.
        val resent = bodyJson.parseToJsonElement(bodyJson.encodeToString(rule)).jsonObject
        assertEquals(
            json
                .parseToJsonElement(reply)
                .jsonObject["feedRules"]!!
                .jsonArray[0]
                .jsonObject["conditions"],
            resent["conditions"],
        )
    }

    @Test
    fun `a rule of known fields is editable`() {
        assertTrue(documentedRule.isEditable)
        assertTrue(documentedRule.unknownFields.isEmpty())
        assertTrue(FeedRule().isEditable)
    }

    @Test
    fun `hasAction is any of the three marks`() {
        assertFalse(FeedRule().hasAction)
        assertTrue(FeedRule(flag = true).hasAction)
        assertTrue(FeedRule(markRead = true).hasAction)
        assertTrue(FeedRule(flags = listOf("cabal-flag-01")).hasAction)
    }

    @Test
    fun `the rule's feed is its feed condition`() {
        assertEquals("sub-1", documentedRule.feedSubscriptionId)
        assertNull(FeedRule(conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, "x"))).feedSubscriptionId)
        assertEquals(listOf(FeedRuleCondition(FeedRuleField.TITLE, "release")), documentedRule.textConditions)
    }

    @Test
    fun `picking a feed adds the condition at the head`() {
        val rule = FeedRule(conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, "x")))

        assertEquals(
            listOf(FeedRuleCondition(FeedRuleField.FEED, "sub-9"), FeedRuleCondition(FeedRuleField.TITLE, "x")),
            rule.withFeed("sub-9").conditions,
        )
    }

    @Test
    fun `picking another feed rewrites the condition where it stands`() {
        val rule =
            FeedRule(
                conditions =
                    listOf(
                        FeedRuleCondition(FeedRuleField.TITLE, "x"),
                        FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                        FeedRuleCondition(FeedRuleField.AUTHOR, "y"),
                    ),
            )

        assertEquals(
            listOf(
                FeedRuleCondition(FeedRuleField.TITLE, "x"),
                FeedRuleCondition(FeedRuleField.FEED, "sub-2"),
                FeedRuleCondition(FeedRuleField.AUTHOR, "y"),
            ),
            rule.withFeed("sub-2").conditions,
        )
    }

    @Test
    fun `all feeds removes the condition and leaves the rest`() {
        assertEquals(
            listOf(FeedRuleCondition(FeedRuleField.TITLE, "release")),
            documentedRule.withFeed(null).conditions,
        )
        // Nothing to remove is no change.
        val plain = FeedRule(conditions = listOf(FeedRuleCondition(FeedRuleField.TITLE, "x")))
        assertEquals(plain, plain.withFeed(null))
    }

    @Test
    fun `a rule never comes out of the picker with two feed conditions`() {
        // Another client could not have stored two (the server refuses a
        // second), but a pick must not be the thing that keeps one alive.
        val doubled =
            FeedRule(
                conditions =
                    listOf(
                        FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                        FeedRuleCondition(FeedRuleField.TITLE, "x"),
                        FeedRuleCondition(FeedRuleField.FEED, "sub-2"),
                    ),
            )

        assertEquals(
            listOf(FeedRuleCondition(FeedRuleField.FEED, "sub-3"), FeedRuleCondition(FeedRuleField.TITLE, "x")),
            doubled.withFeed("sub-3").conditions,
        )
        assertEquals(listOf(FeedRuleCondition(FeedRuleField.TITLE, "x")), doubled.withFeed(null).conditions)
    }

    @Test
    fun `editing the condition rows leaves the feed condition in place`() {
        val edited =
            documentedRule.withTextConditions(
                listOf(FeedRuleCondition(FeedRuleField.AUTHOR, "a"), FeedRuleCondition(FeedRuleField.SUMMARY, "b")),
            )

        assertEquals(
            listOf(
                FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                FeedRuleCondition(FeedRuleField.AUTHOR, "a"),
                FeedRuleCondition(FeedRuleField.SUMMARY, "b"),
            ),
            edited.conditions,
        )
        assertEquals("sub-1", edited.feedSubscriptionId)
        // Removing every row leaves the feed alone.
        assertEquals(
            listOf(FeedRuleCondition(FeedRuleField.FEED, "sub-1")),
            documentedRule.withTextConditions(emptyList()).conditions,
        )
    }

    @Test
    fun `condition rows keep their place around a feed condition stored mid-list`() {
        val rule =
            FeedRule(
                conditions =
                    listOf(
                        FeedRuleCondition(FeedRuleField.TITLE, "x"),
                        FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                        FeedRuleCondition(FeedRuleField.AUTHOR, "y"),
                    ),
            )

        val retyped = rule.textConditions.map { it.copy(value = it.value + "!") }

        assertEquals(
            listOf(
                FeedRuleCondition(FeedRuleField.TITLE, "x!"),
                FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                FeedRuleCondition(FeedRuleField.AUTHOR, "y!"),
            ),
            rule.withTextConditions(retyped).conditions,
        )
    }
}
