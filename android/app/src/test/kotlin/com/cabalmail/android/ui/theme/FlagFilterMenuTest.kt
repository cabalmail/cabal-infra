package com.cabalmail.android.ui.theme

import com.cabalmail.android.R
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The Flagged pill as a menu (`flags-and-cross-media.md`, decision 4): when
 * it is one, its rows and which is checked, what choosing a row does, and
 * the lit pill's words. The Kotlin sibling of the Apple app's
 * `FlagFilterMenuPolicyTests`.
 */
class FlagFilterMenuTest {
    private val later = FlagPaletteEntry(slot = "cabal-flag-01", label = "Later", color = "blue")
    private val work = FlagPaletteEntry(slot = "cabal-flag-02", label = "Work", color = "green")
    private val builtIn = FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)

    private fun system(label: String = "Flagged") =
        FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = "yellow")

    private fun pickOf(entry: FlagPaletteEntry) = FlagCriterion.Slot(entry.slot)

    @Test
    fun `with the built-in flag alone the pill stays a toggle`() {
        assertFalse(FlagFilterMenu.isMenu(emptyList(), pick = null))
        assertFalse(FlagFilterMenu.isMenu(listOf(system("Starred")), pick = null), "renamed, it is still the only flag")
        assertTrue(FlagFilterMenu.isMenu(listOf(later), pick = null))
        // A pick still in force when the last flag of the user's own is
        // deleted needs a way out: the menu, with Clear filter.
        assertTrue(FlagFilterMenu.isMenu(emptyList(), pick = pickOf(later)))
        assertTrue(FlagFilterMenu.isMenu(emptyList(), pick = FlagCriterion.AnyFlag))
    }

    @Test
    fun `the pill is lit by the remembered filter or by a pick`() {
        assertFalse(FlagFilterMenu.isLit(builtInLit = false, pick = null))
        assertTrue(FlagFilterMenu.isLit(builtInLit = true, pick = null))
        assertTrue(FlagFilterMenu.isLit(builtInLit = false, pick = pickOf(later)))
        assertTrue(FlagFilterMenu.isLit(builtInLit = false, pick = FlagCriterion.AnyFlag))
    }

    @Test
    fun `the rows are every flag in the list's order, then Any flag`() {
        val rows = FlagFilterMenu.rows(listOf(work, system("Starred"), later), builtInLit = false, pick = null)

        assertEquals(
            listOf(
                FlagFilterRow(pickOf(work), UiLabel.Verbatim("Work"), "green", isChecked = false),
                FlagFilterRow(builtIn, UiLabel.Verbatim("Starred"), "yellow", isChecked = false),
                FlagFilterRow(pickOf(later), UiLabel.Verbatim("Later"), "blue", isChecked = false),
                FlagFilterRow(FlagCriterion.AnyFlag, UiLabel.Fixed(R.string.flag_filter_any), null, isChecked = false),
            ),
            rows,
        )
        // A list that stores no entry for the built-in flag leads with it.
        assertEquals(
            listOf(builtIn, pickOf(later), FlagCriterion.AnyFlag),
            FlagFilterMenu.rows(listOf(later), builtInLit = false, pick = null).map { it.criterion },
        )
    }

    private fun checked(
        builtInLit: Boolean,
        pick: FlagCriterion?,
    ) = FlagFilterMenu.rows(listOf(later, work), builtInLit, pick).filter { it.isChecked }.map { it.criterion }

    @Test
    fun `one row at most is checked, and a pick takes the check from the built-in flag`() {
        assertEquals(emptyList<FlagCriterion>(), checked(builtInLit = false, pick = null))
        assertEquals(listOf(builtIn), checked(builtInLit = true, pick = null))
        assertEquals(listOf(pickOf(work)), checked(builtInLit = false, pick = pickOf(work)))
        assertEquals(listOf(FlagCriterion.AnyFlag), checked(builtInLit = false, pick = FlagCriterion.AnyFlag))
        // The folder remembers Flagged, and a pick is in force over it.
        assertEquals(listOf(pickOf(later)), checked(builtInLit = true, pick = pickOf(later)))
        // A pick of a flag deleted since has no row to check.
        assertEquals(
            emptyList<FlagCriterion>(),
            checked(builtInLit = false, pick = FlagCriterion.Slot("cabal-flag-09")),
        )
    }

    @Test
    fun `the built-in flag's row is the remembered filter and every other row a pick`() {
        val rows = FlagFilterMenu.rows(listOf(later), builtInLit = false, pick = null)

        assertEquals(
            listOf(
                FlagFilterChoice.BuiltIn,
                FlagFilterChoice.Pick(pickOf(later)),
                FlagFilterChoice.Pick(FlagCriterion.AnyFlag),
            ),
            rows.map(FlagFilterMenu::choice),
        )
    }

    @Test
    fun `the lit pill carries the picked flag's name, cut when it is long`() {
        val palette = listOf(later, system("Starred"))
        val long = FlagPaletteEntry(slot = "cabal-flag-03", label = "A name of thirty-two characters!", color = "red")

        assertEquals(UiLabel.Verbatim("Starred"), FlagFilterMenu.pillLabel(palette, pick = null))
        assertEquals(UiLabel.Verbatim("Flagged"), FlagFilterMenu.pillLabel(listOf(later), pick = null))
        assertEquals(UiLabel.Verbatim("Later"), FlagFilterMenu.pillLabel(palette, pickOf(later)))
        assertEquals(UiLabel.Fixed(R.string.flag_filter_any), FlagFilterMenu.pillLabel(palette, FlagCriterion.AnyFlag))
        assertEquals(
            UiLabel.Verbatim("A name of thirty-tw…"),
            FlagFilterMenu.pillLabel(listOf(long), pickOf(long)),
            "nineteen characters and an ellipsis",
        )
        assertEquals(
            UiLabel.Verbatim("Exactly twenty chars"),
            FlagFilterMenu.pillLabel(listOf(long.copy(label = "Exactly twenty chars")), pickOf(long)),
        )
        assertEquals(
            "A name of thirty-two characters!",
            FlagFilterMenu.name(listOf(long), pickOf(long)),
            "whole elsewhere",
        )
        // The flag was deleted while it was picked.
        assertEquals(
            UiLabel.Verbatim("cabal-flag-09"),
            FlagFilterMenu.pillLabel(palette, FlagCriterion.Slot("cabal-flag-09")),
        )
    }
}
