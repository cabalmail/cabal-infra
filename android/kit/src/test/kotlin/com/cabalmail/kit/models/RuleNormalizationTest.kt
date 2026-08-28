package com.cabalmail.kit.models

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Truthful-Continue normalization (the Kotlin sibling of the Apple kit's
 * `RuleModelTests` normalization cases): legacy `move`/`archive` +
 * spill-through renders and saves as the Copy it compiles to, and `delete` +
 * spill-through drops the flag the compiler ignores.
 */
class RuleNormalizationTest {
    @Test
    fun `move with continue becomes copy carrying the folder`() {
        val rule = Rule(name = "n", action = RuleAction.MOVE, moveFolder = "Receipts", continueToNext = true)

        val normalized = rule.normalizeLegacyContinue()

        assertEquals(RuleAction.COPY, normalized.action)
        assertEquals(listOf("Receipts"), normalized.copyFolders)
        assertTrue(normalized.continueToNext)
    }

    @Test
    fun `a folderless move with continue becomes a folderless copy`() {
        val rule = Rule(name = "n", action = RuleAction.MOVE, continueToNext = true)

        assertEquals(emptyList<String>(), rule.normalizeLegacyContinue().copyFolders)
    }

    @Test
    fun `archive with continue becomes copy to the Archive folder`() {
        val rule = Rule(name = "n", action = RuleAction.ARCHIVE, continueToNext = true)

        val normalized = rule.normalizeLegacyContinue()

        assertEquals(RuleAction.COPY, normalized.action)
        assertEquals(listOf("Archive"), normalized.copyFolders)
    }

    @Test
    fun `delete with continue drops the flag the engine ignores`() {
        val rule = Rule(name = "n", action = RuleAction.DELETE, continueToNext = true)

        val normalized = rule.normalizeLegacyContinue()

        assertEquals(RuleAction.DELETE, normalized.action)
        assertFalse(normalized.continueToNext)
    }

    @Test
    fun `terminal rules and continuing copy or none rules are untouched`() {
        for (action in RuleAction.entries) {
            val terminal = Rule(name = "n", action = action, moveFolder = "F")
            assertEquals(terminal, terminal.normalizeLegacyContinue())
        }
        val copy = Rule(name = "n", action = RuleAction.COPY, copyFolders = listOf("A"), continueToNext = true)
        assertEquals(copy, copy.normalizeLegacyContinue())
        val none = Rule(name = "n", action = RuleAction.NONE, flag = true, continueToNext = true)
        assertEquals(none, none.normalizeLegacyContinue())
    }
}
