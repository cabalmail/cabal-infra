package com.cabalmail.kit.models

import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/**
 * Encode/decode coverage for [Rule] / [RuleSet] against the wire shape the
 * `/get_rules` / `/set_rules` Lambdas speak (`lambda/api/set_rules/
 * function.py` `DEFAULTS` is the canonical key set). Mirrors the Apple
 * kit's `RuleModelTests`.
 */
class RulesModelsTest {
    // The client's read config (unknown keys tolerated)...
    private val json = Json { ignoreUnknownKeys = true }

    // ...and its request-body config (defaults always on the wire).
    private val bodyJson =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }

    private val fullRuleJson =
        """
        {"id":"r-0123456789ab","name":"Receipts","enabled":true,
         "conditions":[{"field":"subject","value":"invoice"},{"field":"from","value":"aws"}],
         "action":"move","moveFolder":"Receipts/2026","copyFolders":["Audit"],
         "flag":true,"markRead":true,"forward":["ops@example.com"],
         "reply":true,"replyBody":"On vacation.","continueToNext":true}
        """.trimIndent()

    @Test
    fun `decodes a full rule`() {
        val rule = json.decodeFromString<Rule>(fullRuleJson)

        assertEquals("r-0123456789ab", rule.id)
        assertEquals("Receipts", rule.name)
        assertEquals(listOf(RuleField.SUBJECT, RuleField.FROM), rule.conditions.map { it.field })
        assertEquals(listOf("invoice", "aws"), rule.conditions.map { it.value })
        assertEquals(RuleAction.MOVE, rule.action)
        assertEquals("Receipts/2026", rule.moveFolder)
        assertEquals(listOf("Audit"), rule.copyFolders)
        assertTrue(rule.flag)
        assertTrue(rule.markRead)
        assertEquals(listOf("ops@example.com"), rule.forward)
        assertTrue(rule.reply)
        assertEquals("On vacation.", rule.replyBody)
        assertTrue(rule.continueToNext)
    }

    @Test
    fun `round-trips every action and field`() {
        for (action in RuleAction.entries) {
            for (field in RuleField.entries) {
                val original =
                    Rule(
                        name = "$action-$field",
                        conditions = listOf(RuleCondition(field = field, value = "x")),
                        action = action,
                    )

                val decoded = bodyJson.decodeFromString<Rule>(bodyJson.encodeToString(original))

                assertEquals(original, decoded)
            }
        }
    }

    @Test
    fun `encoded rule carries every wire key`() {
        // The Lambda replaces the whole row per save; a dropped key would
        // read back as its default and silently reset that setting.
        val encoded = bodyJson.parseToJsonElement(bodyJson.encodeToString(Rule(name = "n"))).jsonObject

        assertEquals(
            setOf(
                "id",
                "name",
                "enabled",
                "conditions",
                "action",
                "moveFolder",
                "copyFolders",
                "flag",
                "markRead",
                "forward",
                "reply",
                "replyBody",
                "continueToNext",
            ),
            encoded.keys,
        )
        // Conditions encode only field/value (no client-side extras).
        val condition =
            bodyJson
                .parseToJsonElement(bodyJson.encodeToString(Rule(conditions = listOf(RuleCondition()))))
                .jsonObject["conditions"]!!
                .jsonArray[0]
                .jsonObject
        assertEquals(setOf("field", "value"), condition.keys)
    }

    @Test
    fun `empty flags stays off the wire and non-empty rides`() {
        // A server predating the `flags` key rejects unknown fields, so an
        // empty list is omitted (the server defaults it to []); a
        // non-empty list — only authorable via the palette picker — rides
        // and round-trips.
        val plain = bodyJson.parseToJsonElement(bodyJson.encodeToString(Rule(name = "n"))).jsonObject
        assertFalse("flags" in plain.keys)

        val tagged = Rule(name = "n", flags = listOf("cabal-flag-03"))
        val encoded = bodyJson.encodeToString(tagged)
        assertTrue("\"flags\":[\"cabal-flag-03\"]" in encoded)
        assertEquals(tagged, json.decodeFromString<Rule>(encoded))
        // ...and a missing key decodes as the empty default.
        assertTrue(json.decodeFromString<Rule>("{}").flags.isEmpty())
    }

    @Test
    fun `missing keys decode as the lambda defaults`() {
        val rule = json.decodeFromString<Rule>("{}")

        assertEquals("", rule.name)
        assertTrue(rule.enabled)
        assertTrue(rule.conditions.isEmpty())
        assertEquals(RuleAction.NONE, rule.action)
        assertEquals("", rule.moveFolder)
        assertTrue(rule.copyFolders.isEmpty())
        assertFalse(rule.flag)
        assertFalse(rule.markRead)
        assertTrue(rule.forward.isEmpty())
        assertFalse(rule.reply)
        assertEquals("", rule.replyBody)
        assertFalse(rule.continueToNext)
        // Like the server, a missing id is minted rather than left colliding.
        assertTrue(rule.id.startsWith("r-"))
    }

    @Test
    fun `unknown field or action fails the decode`() {
        // A `bcc` condition or a future action must fail rather than be
        // silently coerced (and rewritten on the next whole-set save).
        assertThrows<SerializationException> {
            json.decodeFromString<Rule>("""{"conditions":[{"field":"bcc","value":"x"}]}""")
        }
        assertThrows<SerializationException> {
            json.decodeFromString<Rule>("""{"action":"quarantine"}""")
        }
    }

    @Test
    fun `rule set decodes wire shape and defaults`() {
        val ruleSet =
            json.decodeFromString<RuleSet>(
                """{"rules":[{"id":"r-0123456789ab","name":"A"}],"version":7,
                    "updatedAt":"2026-08-25T00:00:00+00:00"}""",
            )

        assertEquals(1, ruleSet.rules.size)
        assertEquals(7, ruleSet.version)
        assertEquals("2026-08-25T00:00:00+00:00", ruleSet.updatedAt)
        // A user with no saved row (`lambda/api/get_rules/function.py`) —
        // and a fully-empty body reads the same rather than erroring.
        assertEquals(0, json.decodeFromString<RuleSet>("{}").version)
        assertTrue(json.decodeFromString<RuleSet>("{}").rules.isEmpty())
    }

    @Test
    fun `minted ids match the server format`() {
        // The Lambda keeps client ids matching ^r-[0-9a-f]{12}$ and re-mints
        // anything else; a drifting local format would re-id every rule on
        // each save.
        repeat(100) {
            val id = mintRuleId()
            assertEquals(14, id.length)
            assertTrue(id.startsWith("r-"))
            assertTrue(id.drop(2).all { it in "0123456789abcdef" })
        }
        assertNotEquals(mintRuleId(), mintRuleId())
    }
}
