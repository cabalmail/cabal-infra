package com.cabalmail.android.ui.settings

import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The edits Settings > Flags makes (unified-flags plan, decision 2): they
 * act on the list as shown, the built-in flag's entry included, and store
 * that entry only once the user has changed it. The Kotlin sibling of the
 * Apple app's `FlagPaletteEntryBindingsTests`.
 */
class FlagPaletteEditsTest {
    private val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
    private val waiting = FlagPaletteEntry(slot = "cabal-flag-02", label = "Waiting", color = "blue")
    private val system = FlagPalette.DEFAULT_SYSTEM_ENTRY

    @Test
    fun `the built-in entry is editable before it is stored, and an edit stores it first`() {
        val renamed = system.copy(label = "Urgent!")
        assertEquals(listOf(renamed, urgent), FlagPaletteEdits.changed(listOf(urgent), renamed))
        val recolored = system.copy(color = "red")
        assertEquals(listOf(recolored), FlagPaletteEdits.changed(emptyList(), recolored))
    }

    @Test
    fun `editing another flag leaves the built-in entry unstored`() {
        val renamed = urgent.copy(label = "Now")
        assertEquals(listOf(renamed, waiting), FlagPaletteEdits.changed(listOf(urgent, waiting), renamed))
        // An entry deleted on another device while its dialog was open: the
        // edit has nothing to land on and writes nothing.
        assertEquals(listOf(waiting), FlagPaletteEdits.changed(listOf(waiting), renamed))
    }

    @Test
    fun `adding a flag takes the lowest free slot and does not store the built-in entry`() {
        assertEquals(
            listOf(FlagPaletteEntry("cabal-flag-01", "New flag", FlagPalette.COLORS.first())),
            FlagPaletteEdits.added(emptyList(), "New flag"),
        )
        assertEquals(
            listOf("cabal-flag-02", "cabal-flag-01"),
            FlagPaletteEdits.added(listOf(waiting), "New flag").map { it.slot },
        )
        // A stored built-in entry keeps its place and uses up no slot.
        val stored = listOf(urgent, system.copy(label = "Later"))
        assertEquals(
            listOf("cabal-flag-01", FlagPalette.SYSTEM_SLOT, "cabal-flag-02"),
            FlagPaletteEdits.added(stored, "New flag").map { it.slot },
        )
    }

    @Test
    fun `adding stops at twenty flags of the user's own`() {
        val full = FlagPalette.SLOTS.map { FlagPaletteEntry(it, "x", "red") }
        assertEquals(full, FlagPaletteEdits.added(full, "New flag"))
        val fullWithSystem = listOf(system.copy(label = "Later")) + full
        assertEquals(FlagPalette.MAX_ENTRIES, fullWithSystem.size)
        assertEquals(fullWithSystem, FlagPaletteEdits.added(fullWithSystem, "New flag"))
    }

    @Test
    fun `the first row is the built-in entry, so that is the row that cannot move up`() {
        val stored = listOf(urgent, waiting)
        assertFalse(FlagPaletteEdits.canMove(stored, FlagPalette.SYSTEM_SLOT, -1))
        assertTrue(FlagPaletteEdits.canMove(stored, FlagPalette.SYSTEM_SLOT, 1))
        assertTrue(FlagPaletteEdits.canMove(stored, urgent.slot, -1))
        assertFalse(FlagPaletteEdits.canMove(stored, waiting.slot, 1))
        assertFalse(FlagPaletteEdits.canMove(stored, "cabal-flag-09", 1))
        assertFalse(FlagPaletteEdits.canMove(stored, urgent.slot, 0))
        // Alone in the list it cannot move at all, and nothing is written.
        assertFalse(FlagPaletteEdits.canMove(emptyList(), FlagPalette.SYSTEM_SLOT, 1))
        assertEquals(emptyList<FlagPaletteEntry>(), FlagPaletteEdits.moved(emptyList(), FlagPalette.SYSTEM_SLOT, 1))
    }

    @Test
    fun `moving a flag above the built-in entry stores the order`() {
        val stored = listOf(urgent, waiting)
        // Up past the built-in entry: its place is now the edit.
        assertEquals(listOf(urgent, system, waiting), FlagPaletteEdits.moved(stored, urgent.slot, -1))
        // The built-in entry moved down says the same thing.
        assertEquals(listOf(urgent, system, waiting), FlagPaletteEdits.moved(stored, FlagPalette.SYSTEM_SLOT, 1))
        // A move that leaves it first stores nothing new.
        assertEquals(listOf(waiting, urgent), FlagPaletteEdits.moved(stored, waiting.slot, -1))
        // Past either end nothing is written.
        assertEquals(stored, FlagPaletteEdits.moved(stored, waiting.slot, 1))
    }

    /** A palette as an older build stored it: "Urgent" first and switched off, then the built-in flag. */
    private val olderBuildPalette =
        FlagPalette.decode(
            """[{"slot":"cabal-flag-01","label":"Urgent","color":"red","enabled":false},""" +
                """{"slot":"\\Flagged","label":"Flagged","color":"yellow"},""" +
                """{"slot":"cabal-flag-02","label":"Waiting","color":"blue","enabled":false}]""",
        )!!

    @Test
    fun `the default flag is the first one`() {
        assertTrue(FlagPaletteEdits.isDefault(emptyList(), FlagPalette.SYSTEM_SLOT))
        assertTrue(FlagPaletteEdits.isDefault(listOf(urgent), FlagPalette.SYSTEM_SLOT))
        assertFalse(FlagPaletteEdits.isDefault(listOf(urgent), urgent.slot))
        assertTrue(FlagPaletteEdits.isDefault(listOf(urgent, system), urgent.slot))
        // A first entry an older build switched off is the default all the
        // same. It used to be passed over for the next one.
        assertTrue(FlagPaletteEdits.isDefault(olderBuildPalette, urgent.slot))
        assertFalse(FlagPaletteEdits.isDefault(olderBuildPalette, FlagPalette.SYSTEM_SLOT))
    }

    @Test
    fun `make default moves a flag to the top, and the order is what is stored`() {
        val stored = listOf(urgent, waiting)
        assertTrue(FlagPaletteEdits.canMakeDefault(stored, waiting.slot))
        assertEquals(listOf(waiting, system, urgent), FlagPaletteEdits.madeDefault(stored, waiting.slot))
        // The built-in flag made the default again, from below.
        val reordered = listOf(waiting, system, urgent)
        assertTrue(FlagPaletteEdits.canMakeDefault(reordered, FlagPalette.SYSTEM_SLOT))
        assertEquals(listOf(system, waiting, urgent), FlagPaletteEdits.madeDefault(reordered, FlagPalette.SYSTEM_SLOT))
    }

    @Test
    fun `make default is not offered for the default or for a flag that is gone`() {
        val stored = listOf(urgent, waiting)
        assertFalse(FlagPaletteEdits.canMakeDefault(stored, FlagPalette.SYSTEM_SLOT))
        assertFalse(FlagPaletteEdits.canMakeDefault(stored, "cabal-flag-09"))
        assertEquals(stored, FlagPaletteEdits.madeDefault(stored, FlagPalette.SYSTEM_SLOT))
        assertEquals(stored, FlagPaletteEdits.madeDefault(stored, "cabal-flag-09"))
    }

    @Test
    fun `a flag an older build switched off can be made the default`() {
        // It was refused: a switched-off flag was offered nowhere.
        assertTrue(FlagPaletteEdits.canMakeDefault(olderBuildPalette, waiting.slot))
        assertEquals(
            listOf(waiting.slot, urgent.slot, FlagPalette.SYSTEM_SLOT),
            FlagPaletteEdits.madeDefault(olderBuildPalette, waiting.slot).map { it.slot },
        )
        // The first one is the default already, so there is nothing to do.
        assertFalse(FlagPaletteEdits.canMakeDefault(olderBuildPalette, urgent.slot))
    }

    @Test
    fun `reset drops the stored entry and is offered only when there is one`() {
        assertFalse(FlagPaletteEdits.canReset(listOf(urgent)))
        val stored = listOf(urgent, system.copy(label = "Later", color = "teal"))
        assertTrue(FlagPaletteEdits.canReset(stored))
        assertEquals(listOf(urgent), FlagPaletteEdits.reset(stored))
        assertEquals(listOf(system, urgent), FlagPalette.effective(FlagPaletteEdits.reset(stored)))
        // Moved but otherwise untouched: still stored, so still resettable.
        assertTrue(FlagPaletteEdits.canReset(listOf(urgent, system)))
        assertEquals(listOf(urgent), FlagPaletteEdits.reset(listOf(urgent)))
    }

    @Test
    fun `deleting removes a flag of the user's own and resets the built-in one`() {
        assertEquals(listOf(waiting), FlagPaletteEdits.deleted(listOf(urgent, waiting), urgent.slot))
        val stored = listOf(urgent, system.copy(label = "Later"))
        assertEquals(listOf(urgent), FlagPaletteEdits.deleted(stored, FlagPalette.SYSTEM_SLOT))
        // Nothing can take the built-in entry out of the list as shown.
        assertTrue(
            FlagPalette.effective(FlagPaletteEdits.deleted(stored, FlagPalette.SYSTEM_SLOT)).any {
                it.slot ==
                    FlagPalette.SYSTEM_SLOT
            },
        )
        assertTrue(FlagPaletteEdits.isSystemEntry(FlagPalette.SYSTEM_SLOT))
        assertFalse(FlagPaletteEdits.isSystemEntry(urgent.slot))
    }
}
