package com.cabalmail.kit.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The typed settings held to what `set_preferences` takes (#2453), the
 * Kotlin sibling of the Apple kit's `ServerTextRulesTests`. The server's
 * checks are written out here from `lambda/api/set_preferences/function.py`
 * ([serverTakesLabel] and its neighbours), counted as Python's `len()`
 * counts, in code points, so the rules are tested against the server's
 * words and not their own.
 */
class ServerTextRulesTest {
    private val thumbsUp = "👍🏽"

    private fun codePoints(text: String) = text.codePointCount(0, text.length)

    private fun hasControl(
        text: String,
        allowed: String = "",
    ) = text.any { (it.code < 32 || it.code == 127) && it !in allowed }

    private fun serverTakesLabel(label: String) = codePoints(label) in 1..32 && !hasControl(label)

    private fun serverTakesSignature(signature: String) =
        codePoints(signature) <= 2000 && !hasControl(signature, "\n\t")

    private fun serverTakesName(name: String) = codePoints(name.trim()) <= 100 && !hasControl(name.trim())

    @Test
    fun `a flag's name is cut by code points, at a character boundary`() {
        // 20 characters, 40 code points, 80 UTF-16 units. `take(32)` kept
        // 32 units: 8 characters. The server takes 16.
        val label = ServerTextRules.flagLabel(thumbsUp.repeat(20))
        assertEquals(thumbsUp.repeat(16), label)
        assertTrue(serverTakesLabel(label))
        // A boundary that would split a character keeps the character out.
        assertEquals("a".repeat(31), ServerTextRules.flagLabel("a".repeat(31) + thumbsUp))
        assertEquals("a".repeat(32), ServerTextRules.flagLabel("a".repeat(40)))
    }

    @Test
    fun `a flag's name loses its control characters`() {
        assertEquals("Later", ServerTextRules.flagLabel("La\tte\nr\u007F"))
        assertEquals("", ServerTextRules.flagLabel("\n\u0000"))
        assertFalse(serverTakesLabel("La\tter"))
    }

    @Test
    fun `the signature keeps newlines and tabs and is cut at 2000 code points`() {
        assertEquals("Regards\n\tC", ServerTextRules.signature("Regards\r\n\tC\u0007"))
        assertEquals("a\nb", ServerTextRules.signature("a\rb"))
        val long = ServerTextRules.signature("Regards\r\n".repeat(300))
        assertEquals(2000, codePoints(long))
        assertTrue(serverTakesSignature(long))
        assertFalse(serverTakesSignature("Regards\r\n".repeat(300)))
        val emoji = ServerTextRules.signature(thumbsUp.repeat(1001))
        assertEquals(thumbsUp.repeat(1000), emoji)
    }

    @Test
    fun `the display name is trimmed, loses control characters and is cut at 100 code points`() {
        assertEquals("Chris", ServerTextRules.displayName("  Chris\n "))
        val long = ServerTextRules.displayName("n".repeat(150))
        assertEquals(100, codePoints(long))
        assertTrue(serverTakesName(long))
        assertFalse(serverTakesName("n".repeat(150)))
        // A cut that ends on a space leaves nothing for the server to trim.
        val spaced = ServerTextRules.displayName("n".repeat(99) + " " + "n".repeat(20))
        assertEquals("n".repeat(99), spaced)
        assertEquals("", ServerTextRules.displayName("   "))
    }

    @Test
    fun `a value already within the rules is left as it is`() {
        assertEquals("Later", ServerTextRules.flagLabel("Later"))
        assertEquals("Cheers,\nC", ServerTextRules.signature("Cheers,\nC"))
        assertEquals("Chris C", ServerTextRules.displayName("Chris C"))
    }

    @Test
    fun `a stored flag with an empty name gets its default one`() {
        // What builds up to 1.53.0 could store. The server refuses a
        // palette with such an entry.
        val stored =
            listOf(
                FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = "", color = "orange"),
                FlagPaletteEntry(slot = "cabal-flag-01", label = "", color = "red"),
                FlagPaletteEntry(slot = "cabal-flag-02", label = "Work", color = "blue"),
                FlagPaletteEntry(slot = "cabal-flag-03", label = "a".repeat(40), color = "teal"),
            )
        val accepted = FlagPalette.accepted(stored)
        assertEquals(listOf("Flagged", "New flag", "Work", "a".repeat(32)), accepted.map { it.label })
        assertEquals(stored.map { it.slot to it.color }, accepted.map { it.slot to it.color })
        assertTrue(accepted.all { serverTakesLabel(it.label) })
        assertFalse(stored.all { serverTakesLabel(it.label) })
    }
}
