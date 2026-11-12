package com.cabalmail.android.ui.rules

import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The rule editor's flag list (unified-flags plan, decision 7): the flags
 * as Settings > Flags lists them, the built-in one among them, over a rule
 * that is unchanged on the wire. The built-in flag's toggle is the rule's
 * `flag`; `set_rules` refuses its atom in `flags`, so it must never be
 * written there.
 */
class RuleFlagRowsTest {
    private val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
    private val muted = FlagPaletteEntry(slot = "cabal-flag-02", label = "Muted", color = "gray")
    private val rule = Rule(name = "r")

    private fun system(label: String = "Flagged") =
        FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = "yellow")

    @Test
    fun `an untouched palette offers the built-in flag alone, reading the rule's flag`() {
        assertEquals(
            listOf(RuleFlagRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = false)),
            ruleFlagRows(emptyList(), rule),
        )
        assertTrue(ruleFlagRows(emptyList(), rule.copy(flag = true)).single().isOn)
    }

    @Test
    fun `the list follows Settings, the built-in flag where the user put it`() {
        val palette = listOf(urgent, system(label = "Later"), muted)
        assertEquals(
            listOf(
                RuleFlagRow("cabal-flag-01", "Urgent", "red", isOn = true),
                RuleFlagRow(FlagPalette.SYSTEM_SLOT, "Later", "yellow", isOn = false),
                RuleFlagRow("cabal-flag-02", "Muted", "gray", isOn = false),
            ),
            ruleFlagRows(palette, rule.copy(flags = listOf("cabal-flag-01"))),
        )
    }

    @Test
    fun `a flag an older build switched off is offered, the built-in one too`() {
        // The server compiles a rule that sets such a flag, so the editor
        // has to offer it. A switched-off flag of the user's own used to be
        // left out unless the rule already set it.
        val olderBuildPalette =
            FlagPalette.decode(
                """[{"slot":"\\Flagged","label":"Flagged","color":"yellow","enabled":false},""" +
                    """{"slot":"cabal-flag-02","label":"Muted","color":"gray","enabled":false}]""",
            )!!
        assertEquals(
            listOf(
                RuleFlagRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = true),
                RuleFlagRow("cabal-flag-02", "Muted", "gray", isOn = false),
            ),
            ruleFlagRows(olderBuildPalette, rule.copy(flag = true)),
        )
    }

    @Test
    fun `a slot the rule sets whose entry was deleted comes last, for clearing`() {
        val rows = ruleFlagRows(listOf(urgent, muted), rule.copy(flags = listOf("cabal-flag-09", "cabal-flag-02")))
        assertEquals(
            listOf(
                RuleFlagRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = false),
                RuleFlagRow("cabal-flag-01", "Urgent", "red", isOn = false),
                RuleFlagRow("cabal-flag-02", "Muted", "gray", isOn = true),
                RuleFlagRow("cabal-flag-09", "cabal-flag-09", "", isOn = true),
            ),
            rows,
        )
        // A deleted flag the rule does not set is not offered.
        assertFalse(ruleFlagRows(listOf(urgent, muted), rule).any { it.slot == "cabal-flag-09" })
    }

    @Test
    fun `the built-in flag's toggle writes the rule's flag and never its flags list`() {
        val on = rule.copy(flags = listOf("cabal-flag-01")).settingFlag(FlagPalette.SYSTEM_SLOT, true)
        assertTrue(on.flag)
        assertEquals(listOf("cabal-flag-01"), on.flags)
        val off = on.settingFlag(FlagPalette.SYSTEM_SLOT, false)
        assertFalse(off.flag)
        assertEquals(listOf("cabal-flag-01"), off.flags)
    }

    @Test
    fun `any other toggle adds or removes its slot and leaves the rule's flag alone`() {
        val on = rule.copy(flag = true).settingFlag("cabal-flag-01", true)
        assertEquals(listOf("cabal-flag-01"), on.flags)
        assertTrue(on.flag)
        // Setting it twice does not list it twice.
        assertEquals(listOf("cabal-flag-01"), on.settingFlag("cabal-flag-01", true).flags)
        assertEquals(emptyList<String>(), on.settingFlag("cabal-flag-01", false).flags)
    }
}
