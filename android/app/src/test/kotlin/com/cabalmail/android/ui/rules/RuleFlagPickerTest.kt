package com.cabalmail.android.ui.rules

import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Test

/**
 * The slots the rule editor's flag picker writes into a rule's `flags`
 * list: keyword slots only. `set_rules` refuses the built-in flag's atom
 * there (a rule sets that flag through its own `flag` field), so a stored
 * entry for it must never be offered as one of these toggles.
 */
class RuleFlagPickerTest {
    private val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
    private val muted = FlagPaletteEntry(slot = "cabal-flag-02", label = "Muted", color = "gray", enabled = false)
    private val system = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = "Later", color = "teal")

    @Test
    fun `enabled entries in palette order, then stray slots the rule already sets`() {
        assertEquals(listOf("cabal-flag-01"), pickerSlots(listOf(urgent, muted), ruleFlags = emptyList()))
        assertEquals(
            listOf("cabal-flag-01", "cabal-flag-02", "cabal-flag-09"),
            pickerSlots(listOf(urgent, muted), ruleFlags = listOf("cabal-flag-09", "cabal-flag-02")),
        )
    }

    @Test
    fun `a stored built-in entry is never offered as a keyword toggle`() {
        val slots = pickerSlots(listOf(system, urgent, muted), ruleFlags = emptyList())
        assertEquals(listOf("cabal-flag-01"), slots)
        assertFalse(FlagPalette.SYSTEM_SLOT in pickerSlots(listOf(system), ruleFlags = listOf(FlagPalette.SYSTEM_SLOT)))
    }
}
