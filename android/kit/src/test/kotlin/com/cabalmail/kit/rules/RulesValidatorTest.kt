package com.cabalmail.kit.rules

import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Corpus for [RulesValidator], mirroring `lambda/api/set_rules/function.py`
 * and the Apple kit's `RulesValidatorTests` — the aim is that a set passing
 * the client validator is never 400'd (or silently stripped) server-side.
 */
class RulesValidatorTest {
    private fun validRule(): Rule =
        Rule(
            name = "Receipts",
            conditions = listOf(RuleCondition(RuleField.SUBJECT, "invoice")),
            action = RuleAction.MOVE,
            moveFolder = "Receipts",
            forward = listOf("ops@example.com"),
        )

    private fun issueFields(rule: Rule): List<String> = RulesValidator.validate(rule).map { it.field }

    @Test
    fun `a valid rule has no issues`() {
        assertTrue(RulesValidator.validate(listOf(validRule())).isEmpty())
    }

    @Test
    fun `name bounds`() {
        assertEquals(listOf("name"), issueFields(validRule().copy(name = "")))
        assertEquals(listOf("name"), issueFields(validRule().copy(name = "   ")))
        assertEquals(emptyList<String>(), issueFields(validRule().copy(name = "x".repeat(100))))
        assertEquals(listOf("name"), issueFields(validRule().copy(name = "x".repeat(101))))
        assertEquals(listOf("name"), issueFields(validRule().copy(name = "tab\tname")))
        assertEquals(emptyList<String>(), issueFields(validRule().copy(name = "emoji 📫 fine")))
    }

    @Test
    fun `condition value bounds`() {
        fun withValue(value: String) = validRule().copy(conditions = listOf(RuleCondition(RuleField.FROM, value)))

        assertEquals(listOf("conditions[0].value"), issueFields(withValue("")))
        assertEquals(emptyList<String>(), issueFields(withValue("v".repeat(500))))
        assertEquals(listOf("conditions[0].value"), issueFields(withValue("v".repeat(501))))
        assertEquals(listOf("conditions[0].value"), issueFields(withValue("nul\u0000byte")))
        // Injection-corpus flavors are data here, not syntax: the client only
        // enforces the character class, the compiler escapes the rest.
        assertEquals(emptyList<String>(), issueFields(withValue("; rm -rf / \$(x) `y` |z")))
    }

    @Test
    fun `condition count cap`() {
        val many = List(11) { RuleCondition(RuleField.FROM, "v$it") }
        assertEquals(listOf("conditions"), issueFields(validRule().copy(conditions = many)))
        // An empty conditions list is valid (matches every message).
        assertEquals(emptyList<String>(), issueFields(validRule().copy(conditions = emptyList())))
    }

    @Test
    fun `move folder rules`() {
        // Destination not picked yet: allowed.
        assertEquals(emptyList<String>(), issueFields(validRule().copy(moveFolder = "")))
        for (hostile in listOf("a|b", "a>b", "a`b", "/abs", "up/../and-over", "nl\nfolder")) {
            assertEquals(listOf("moveFolder"), issueFields(validRule().copy(moveFolder = hostile)), hostile)
        }
        assertEquals(listOf("moveFolder"), issueFields(validRule().copy(moveFolder = "f".repeat(256))))
        assertEquals(emptyList<String>(), issueFields(validRule().copy(moveFolder = "Parent/Child")))
    }

    @Test
    fun `copy folder rules`() {
        fun withCopies(folders: List<String>) =
            validRule().copy(action = RuleAction.COPY, moveFolder = "", copyFolders = folders)

        assertEquals(emptyList<String>(), issueFields(withCopies(listOf("Audit", "Receipts/2026"))))
        // Unlike moveFolder, an empty copy target is an error.
        assertEquals(listOf("copyFolders[0]"), issueFields(withCopies(listOf(""))))
        assertEquals(listOf("copyFolders[1]"), issueFields(withCopies(listOf("ok", "bad|pipe"))))
        assertEquals(listOf("copyFolders"), issueFields(withCopies(List(11) { "F$it" })))
    }

    @Test
    fun `forward address shapes`() {
        for (valid in listOf("a@b.co", "user+tag@mail.example.com", "x@sub.domain.example", "weird!#$%@host.tld")) {
            assertTrue(RulesValidator.isValidForwardAddress(valid), valid)
        }
        val invalid =
            listOf(
                "",
                "plain",
                "@example.com",
                "user@",
                "user@nodot",
                "two@@at.com",
                "spaced user@example.com",
                "user@exa mple.com",
                "user@.com",
                "user@com.",
                "a@b@c.com",
                "ctrl\u0001@example.com",
                "a".repeat(315) + "@x.com",
            )
        for (address in invalid) {
            assertFalse(RulesValidator.isValidForwardAddress(address), address)
        }
    }

    @Test
    fun `forward list issues`() {
        assertEquals(
            listOf("forward[1]"),
            issueFields(validRule().copy(forward = listOf("ok@example.com", "not-an-email"))),
        )
        assertEquals(
            listOf("forward"),
            issueFields(validRule().copy(forward = List(11) { "user$it@example.com" })),
        )
    }

    @Test
    fun `reply body rules`() {
        val replying = validRule().copy(reply = true)
        assertEquals(listOf("replyBody"), issueFields(replying.copy(replyBody = "")))
        assertEquals(emptyList<String>(), issueFields(replying.copy(replyBody = "Away.\nBack Monday.")))
        assertEquals(listOf("replyBody"), issueFields(replying.copy(replyBody = "CR\r\nis a control")))
        assertEquals(listOf("replyBody"), issueFields(replying.copy(replyBody = "b".repeat(4001))))
        // Length caps count code points like the server's len(): 2001
        // two-unit emoji are 2001 code points (fits), while Kotlin's
        // String.length would call it 4002.
        assertEquals(emptyList<String>(), issueFields(replying.copy(replyBody = "🏝".repeat(2001))))
        // Not required when reply is off.
        assertEquals(emptyList<String>(), issueFields(validRule().copy(reply = false, replyBody = "")))
    }

    @Test
    fun `a continuing rule without an effect is an issue`() {
        // Client-strict, server-permissive: destination None + Continue +
        // nothing outbound compiles to an empty procmail block (`no_effect`)
        // and would silently evaporate.
        val noEffect =
            validRule().copy(
                action = RuleAction.NONE,
                moveFolder = "",
                forward = emptyList(),
                continueToNext = true,
            )
        assertTrue(RulesValidator.hasNoEffect(noEffect))
        assertEquals(listOf("continueToNext"), issueFields(noEffect))

        // A continuing copy with no folders picked yet is the same trap.
        assertEquals(
            listOf("continueToNext"),
            issueFields(noEffect.copy(action = RuleAction.COPY, copyFolders = emptyList())),
        )
    }

    @Test
    fun `effectful and terminal rules are not no-effect`() {
        val continuingNone =
            validRule().copy(action = RuleAction.NONE, moveFolder = "", forward = emptyList(), continueToNext = true)

        // Flag / mark-as-read decorate: the compiler's pending state
        // (rules-composition plan, decision 3) carries them into whatever
        // delivery ends up happening, so a decorate-only rule is saveable.
        assertEquals(emptyList<String>(), issueFields(continuingNone.copy(flag = true)))
        assertEquals(emptyList<String>(), issueFields(continuingNone.copy(markRead = true)))
        // Forward or reply gives a continuing None rule an effect.
        assertEquals(emptyList<String>(), issueFields(continuingNone.copy(forward = listOf("ops@example.com"))))
        assertEquals(emptyList<String>(), issueFields(continuingNone.copy(reply = true, replyBody = "Away.")))
        // A terminal None rule stops processing — that is an effect.
        assertEquals(emptyList<String>(), issueFields(continuingNone.copy(continueToNext = false)))
        // A continuing copy with folders delivers.
        assertEquals(
            emptyList<String>(),
            issueFields(continuingNone.copy(action = RuleAction.COPY, copyFolders = listOf("Audit"))),
        )
    }

    @Test
    fun `rule count cap`() {
        val many = List(101) { Rule(name = "r$it") }

        val issues = RulesValidator.validate(many)

        assertTrue(
            issues.contains(
                RulesValidator.Issue(ruleIndex = null, field = "rules", message = "At most 100 rules."),
            ),
        )
        assertTrue(RulesValidator.validate(many.take(100)).isEmpty())
    }

    @Test
    fun `issues carry the rule index`() {
        val issues = RulesValidator.validate(listOf(validRule(), validRule().copy(name = "")))

        assertEquals(listOf(1), issues.map { it.ruleIndex })
    }
}
