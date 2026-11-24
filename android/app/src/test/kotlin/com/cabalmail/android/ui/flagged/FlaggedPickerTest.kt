package com.cabalmail.android.ui.flagged

import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.UiLabel
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The Flagged view's flag pill (`android-parity.md`, leg L4, question 5):
 * when it is drawn, its rows and which is checked, and its words.
 */
class FlaggedPickerTest {
    private val later = FlagPaletteEntry(slot = "cabal-flag-01", label = "Later", color = "blue")
    private val work = FlagPaletteEntry(slot = "cabal-flag-02", label = "Work", color = "green")
    private val starred = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = "Starred", color = "yellow")
    private val builtIn = FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)

    private fun pickOf(entry: FlagPaletteEntry) = FlagCriterion.Slot(entry.slot)

    @Test
    fun `with the built-in flag alone there is no pill`() {
        assertFalse(FlaggedPicker.isShown(emptyList(), FlagCriterion.AnyFlag))
        assertFalse(FlaggedPicker.isShown(listOf(starred), FlagCriterion.AnyFlag), "renamed, it is still the only flag")
        assertTrue(FlaggedPicker.isShown(listOf(later), FlagCriterion.AnyFlag))
        // A pick still in force when the last flag of the user's own is
        // deleted needs a way back to any flag.
        assertTrue(FlaggedPicker.isShown(emptyList(), pickOf(later)))
        assertTrue(FlaggedPicker.isShown(emptyList(), builtIn))
    }

    @Test
    fun `the pill is lit only while the view is narrowed to one flag`() {
        assertFalse(FlaggedPicker.isNarrowed(FlagCriterion.AnyFlag))
        assertTrue(FlaggedPicker.isNarrowed(builtIn))
        assertTrue(FlaggedPicker.isNarrowed(pickOf(later)))
    }

    @Test
    fun `the rows are every flag in the list's order then Any flag, with the pick checked`() {
        val palette = listOf(work, starred, later)

        fun checked(criterion: FlagCriterion) =
            FlaggedPicker.rows(palette, criterion).filter { it.isChecked }.map { it.criterion }

        assertEquals(
            listOf(pickOf(work), builtIn, pickOf(later), FlagCriterion.AnyFlag),
            FlaggedPicker.rows(palette, FlagCriterion.AnyFlag).map { it.criterion },
        )
        assertEquals(listOf(FlagCriterion.AnyFlag), checked(FlagCriterion.AnyFlag), "what the view opens on")
        assertEquals(listOf(builtIn), checked(builtIn))
        assertEquals(listOf(pickOf(later)), checked(pickOf(later)))
    }

    @Test
    fun `the pill and the empty list name the pick`() {
        val palette = listOf(work, starred, later)

        assertEquals(UiLabel.Fixed(R.string.flag_filter_any), FlaggedPicker.label(palette, FlagCriterion.AnyFlag))
        assertEquals(UiLabel.Verbatim("Later"), FlaggedPicker.label(palette, pickOf(later)))
        assertEquals(
            UiLabel.Verbatim("Starred"),
            FlaggedPicker.label(palette, builtIn),
            "under its name in Settings > Flags",
        )

        assertEquals(
            UiLabel.Fixed(R.string.flagged_empty_any),
            FlaggedPicker.emptyTitle(palette, FlagCriterion.AnyFlag),
        )
        assertEquals(
            UiLabel.Formatted(R.string.flagged_empty_flag, "Work"),
            FlaggedPicker.emptyTitle(palette, pickOf(work)),
        )
        // A picked flag that has since been deleted is named by its slot.
        assertEquals(
            UiLabel.Formatted(R.string.flagged_empty_flag, "cabal-flag-01"),
            FlaggedPicker.emptyTitle(listOf(work), pickOf(later)),
        )
    }
}
