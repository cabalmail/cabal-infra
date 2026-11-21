package com.cabalmail.kit.rules

import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory
import java.io.File

/**
 * [FeedRulesValidator] against [FeedRuleCorpus], which is written out from
 * `_normalize_feed_rules` in `lambda/api/set_rules/function.py`: a list
 * that passes here is never refused by the server, and one the server
 * refuses is held here, on the same field.
 */
class FeedRulesValidatorTest {
    @TestFactory
    fun `the validator agrees with the server on every corpus case`(): List<DynamicTest> =
        FeedRuleCorpus.cases.map { case ->
            DynamicTest.dynamicTest(case.name) {
                assertEquals(case.refusedOn, FeedRulesValidator.validate(case.rules).firstOrNull()?.field)
            }
        }

    @Test
    fun `every issue names the feed list`() {
        val issues = FeedRuleCorpus.cases.flatMap { FeedRulesValidator.validate(it.rules) }

        assertTrue(issues.isNotEmpty())
        assertTrue(issues.all { it.list == FeedRulesValidator.LIST })
        // A mail rule's issue names no list, as the server's do not.
        assertTrue(
            RulesValidator
                .validate(
                    com.cabalmail.kit.models
                        .Rule(name = ""),
                ).all { it.list == null },
        )
    }

    @Test
    fun `an issue names the rule's place in the feed list`() {
        val issues =
            FeedRulesValidator.validate(
                listOf(FeedRule(name = "ok"), FeedRule(name = "ok"), FeedRule(name = "")),
            )

        assertEquals(listOf(2), issues.map { it.ruleIndex })
        assertEquals(
            listOf<Int?>(null),
            FeedRulesValidator.validate(List(101) { FeedRule(name = "r") }).map { it.ruleIndex },
        )
    }

    @Test
    fun `a rule with no action is not an issue`() {
        // The server stores it; the editor says it does nothing yet. Held
        // as an issue, a blank rule would raise an error the moment it is
        // added.
        assertTrue(FeedRulesValidator.validate(listOf(FeedRule(name = "New rule"))).isEmpty())
    }

    @Test
    fun `the single-feed check waits for the shape checks`() {
        // `_feed_condition_errors` returns the shape errors alone when
        // there are any.
        val rule =
            FeedRule(
                name = "r",
                conditions =
                    listOf(
                        FeedRuleCondition(FeedRuleField.FEED, "sub-1"),
                        FeedRuleCondition(FeedRuleField.FEED, ""),
                    ),
            )

        assertEquals(listOf("conditions[1].value"), FeedRulesValidator.validate(rule).map { it.field })
    }

    @Test
    fun `a rule this build cannot render is never an issue`() {
        // It is saved back as it was; nothing here could fix what is wrong
        // with it, and an issue would hold every later save of both lists.
        val opaque =
            FeedRule(
                name = "",
                conditions = listOf(FeedRuleCondition(FeedRuleField("category"), "")),
                flags = listOf("not-a-slot"),
            )

        assertTrue(FeedRulesValidator.validate(listOf(opaque)).isEmpty())
        // ...and the rule beside it is still checked.
        assertEquals(
            listOf(1),
            FeedRulesValidator.validate(listOf(opaque, FeedRule(name = ""))).map { it.ruleIndex },
        )
    }

    @Test
    fun `the limits are the server's`() {
        // MAX_FEED_RULES, and the shared MAX_* of `set_rules/function.py`.
        assertEquals(100, FeedRulesValidator.MAX_RULES)
        assertEquals(100, RulesValidator.MAX_NAME_LENGTH)
        assertEquals(10, RulesValidator.MAX_CONDITIONS)
        assertEquals(500, RulesValidator.MAX_VALUE_LENGTH)
        assertEquals(20, RulesValidator.MAX_RULE_FLAGS)
        assertEquals("feedRules", FeedRulesValidator.LIST)
    }

    /**
     * Not a check of its own: with `FEED_RULE_CORPUS_OUT` naming a file,
     * writes each case as the `feedRules` value a save would carry, with
     * what the server should do to it, so a script can put the same cases
     * to a real `/set_rules`. android-parity.md's leg L3 records such a run.
     */
    @Test
    fun `writes the corpus out when asked`() {
        val path = System.getenv("FEED_RULE_CORPUS_OUT") ?: return
        val bodyJson =
            Json {
                encodeDefaults = true
                explicitNulls = false
            }
        val cases =
            buildJsonArray {
                FeedRuleCorpus.cases.forEach { case ->
                    add(
                        buildJsonObject {
                            put("name", case.name)
                            put("feedRules", bodyJson.encodeToJsonElement(case.rules))
                            put("refusedOn", case.refusedOn)
                        },
                    )
                }
            }
        File(path).writeText(bodyJson.encodeToString(cases))
    }
}
