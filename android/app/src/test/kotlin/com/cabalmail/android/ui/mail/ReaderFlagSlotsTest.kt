package com.cabalmail.android.ui.mail

import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * The reader flag menu's item list (Phase 4): enabled palette entries in
 * palette order, then stray tagged slots whose entry is disabled or
 * deleted — those still need an untag affordance. Pure, no Compose.
 */
class ReaderFlagSlotsTest {
    private val palette =
        listOf(
            FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red"),
            FlagPaletteEntry(slot = "cabal-flag-02", label = "Muted", color = "gray", enabled = false),
        )

    @Test
    fun `enabled entries are always offered with their tagged state`() {
        val items = readerFlagSlots(palette, flags = listOf("cabal-flag-01"))
        assertEquals(
            listOf(Triple("cabal-flag-01", "Urgent", true)),
            items,
        )
        assertEquals(
            listOf(Triple("cabal-flag-01", "Urgent", false)),
            readerFlagSlots(palette, flags = emptyList()),
        )
    }

    @Test
    fun `a tagged disabled slot appears with its label for untagging`() {
        val items = readerFlagSlots(palette, flags = listOf("cabal-flag-02"))
        assertEquals(
            listOf(
                Triple("cabal-flag-01", "Urgent", false),
                Triple("cabal-flag-02", "Muted", true),
            ),
            items,
        )
    }

    @Test
    fun `a tagged deleted slot appears by slot id`() {
        val items = readerFlagSlots(palette, flags = listOf("cabal-flag-09"))
        assertEquals(
            listOf(
                Triple("cabal-flag-01", "Urgent", false),
                Triple("cabal-flag-09", "cabal-flag-09", true),
            ),
            items,
        )
    }

    @Test
    fun `the built-in flag's entry is never a menu row`() {
        // The star button beside the menu toggles that flag; a stored
        // entry for it must not appear a second time in the menu, flagged
        // or not, enabled or not.
        val stored =
            listOf(FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = "Later", color = "teal")) + palette
        assertEquals(
            listOf(Triple("cabal-flag-01", "Urgent", false)),
            readerFlagSlots(stored, flags = listOf("\\Flagged")),
        )
        assertEquals(
            listOf(Triple("cabal-flag-01", "Urgent", false)),
            readerFlagSlots(
                stored.map {
                    it.copy(enabled = it.slot != FlagPalette.SYSTEM_SLOT && it.enabled)
                },
                listOf("\\Flagged"),
            ),
        )
    }

    @Test
    fun `untagged disabled slots are not offered`() {
        assertEquals(
            listOf(Triple("cabal-flag-01", "Urgent", false)),
            readerFlagSlots(palette, flags = emptyList()),
        )
    }
}
