package com.cabalmail.android.ui.settings

import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The edits Settings > Flags makes, as pure functions from the stored
 * palette to the stored palette (`AppPreferences.flagPalette`), addressed by
 * slot rather than by a row index that another device's edit could shift.
 *
 * They read and edit the *effective* palette, the list the screen shows: the
 * stored palette with the built-in flag's entry supplied when it has none.
 * Every result goes back through [FlagPalette.storedAfterEditing], so the
 * built-in entry reaches the preference, and the wire, only once the user
 * has changed it or moved something above it. The Kotlin sibling of the
 * Apple app's `FlagPaletteEntryBindings`.
 */
internal object FlagPaletteEdits {
    /** Whether [slot] is the built-in flag's entry, which resets where the others delete. */
    fun isSystemEntry(slot: String): Boolean = slot == FlagPalette.SYSTEM_SLOT

    /** Whether [moved] would move the entry: false past either end of the list, and once the entry is gone. */
    fun canMove(
        stored: List<FlagPaletteEntry>,
        slot: String,
        delta: Int,
    ): Boolean {
        val palette = FlagPalette.effective(stored)
        val index = palette.indexOfFirst { it.slot == slot }
        return delta != 0 && index >= 0 && index + delta in palette.indices
    }

    /** Moves the entry [delta] places through the list (-1 is up). Unchanged when it cannot move. */
    fun moved(
        stored: List<FlagPaletteEntry>,
        slot: String,
        delta: Int,
    ): List<FlagPaletteEntry> {
        if (!canMove(stored, slot, delta)) return stored
        return edit(stored) { palette ->
            val index = palette.indexOfFirst { it.slot == slot }
            palette.add(index + delta, palette.removeAt(index))
        }
    }

    /** Replaces the entry that has [changed]'s slot. Unchanged once that entry is gone. */
    fun changed(
        stored: List<FlagPaletteEntry>,
        changed: FlagPaletteEntry,
    ): List<FlagPaletteEntry> =
        edit(stored) { palette ->
            val index = palette.indexOfFirst { it.slot == changed.slot }
            if (index >= 0) palette[index] = changed
        }

    /** Appends a new flag on the lowest free keyword slot. Unchanged once all 20 are used. */
    fun added(
        stored: List<FlagPaletteEntry>,
        label: String,
    ): List<FlagPaletteEntry> {
        val slot = FlagPalette.firstFreeSlot(stored) ?: return stored
        return edit(stored) { palette ->
            palette.add(FlagPaletteEntry(slot = slot, label = label, color = FlagPalette.COLORS.first()))
        }
    }

    /**
     * Removes the entry. The built-in flag cannot be deleted, so for its
     * entry this is [reset].
     */
    fun deleted(
        stored: List<FlagPaletteEntry>,
        slot: String,
    ): List<FlagPaletteEntry> = if (isSystemEntry(slot)) reset(stored) else stored.filterNot { it.slot == slot }

    /**
     * Whether [reset] would change anything: the built-in entry is stored,
     * so it is not, or not only, the default one in first place.
     */
    fun canReset(stored: List<FlagPaletteEntry>): Boolean = stored.any { isSystemEntry(it.slot) }

    /**
     * Puts the built-in flag's entry back to its default name, color and
     * first place, by dropping the stored entry.
     */
    fun reset(stored: List<FlagPaletteEntry>): List<FlagPaletteEntry> = FlagPalette.resettingSystemEntry(stored)

    /**
     * Whether [slot] is the default flag, the one the swipe, the star
     * button and the flag shortcut set: the first enabled entry.
     */
    fun isDefault(
        stored: List<FlagPaletteEntry>,
        slot: String,
    ): Boolean = FlagPalette.defaultEntry(stored)?.slot == slot

    /**
     * Whether [madeDefault] would change anything: the entry is there,
     * enabled, and not the default already. A disabled flag is offered
     * nowhere, so it cannot be the one the gestures set.
     */
    fun canMakeDefault(
        stored: List<FlagPaletteEntry>,
        slot: String,
    ): Boolean = FlagPalette.effective(stored).any { it.slot == slot && it.enabled } && !isDefault(stored, slot)

    /**
     * Makes the entry the default flag by moving it to the top of the
     * list: the default is a position, not a field, so every shipped build
     * and the other platforms read it the same way. Unchanged when
     * [canMakeDefault] is false.
     */
    fun madeDefault(
        stored: List<FlagPaletteEntry>,
        slot: String,
    ): List<FlagPaletteEntry> {
        if (!canMakeDefault(stored, slot)) return stored
        return edit(stored) { palette ->
            palette.add(0, palette.removeAt(palette.indexOfFirst { it.slot == slot }))
        }
    }

    private fun edit(
        stored: List<FlagPaletteEntry>,
        mutate: (MutableList<FlagPaletteEntry>) -> Unit,
    ): List<FlagPaletteEntry> {
        val palette = FlagPalette.effective(stored).toMutableList()
        mutate(palette)
        return FlagPalette.storedAfterEditing(palette, previous = stored)
    }
}
