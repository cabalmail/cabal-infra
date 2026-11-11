package com.cabalmail.android.ui.theme

import com.cabalmail.android.R
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Which flag a one-press control acts on and what it calls it
 * (unified-flags plan, decisions 3, 5 and 6), and what the flag menus
 * offer. The Kotlin sibling of the Apple app's `FlagToggleTests` and
 * `FlagMenuPolicyTests`.
 */
class FlagToggleTest {
    private val todo = FlagPaletteEntry(slot = "cabal-flag-01", label = "Todo", color = "blue")
    private val later = FlagPaletteEntry(slot = "cabal-flag-02", label = "Later", color = "teal", enabled = false)

    private fun system(
        label: String = "Flagged",
        color: String = "yellow",
        enabled: Boolean = true,
    ) = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = color, enabled = enabled)

    // ---------------------------------------------------------- which flag

    @Test
    fun `mail's controls act on the first enabled entry`() {
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.defaultFlag(emptyList()))
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.defaultFlag(listOf(todo)))
        assertEquals(FlagToggle("cabal-flag-01", "Todo", "blue"), FlagToggle.defaultFlag(listOf(todo, system())))
        // A disabled entry is passed over, and with every entry disabled
        // there is no default: nothing falls back to the built-in flag.
        assertEquals("cabal-flag-01", FlagToggle.defaultFlag(listOf(later, system(enabled = false), todo))?.slot)
        assertNull(FlagToggle.defaultFlag(listOf(system(enabled = false), later)))
    }

    @Test
    fun `the feed's controls act on the built-in entry wherever it sits`() {
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.systemFlag(listOf(todo)))
        assertEquals(
            FlagToggle(FlagPalette.SYSTEM_SLOT, "Urgent", "red"),
            FlagToggle.systemFlag(listOf(todo, system(label = "Urgent", color = "red"))),
        )
        assertNull(FlagToggle.systemFlag(listOf(todo, system(enabled = false))))
    }

    @Test
    fun `the filters take the built-in flag's name, enabled or not`() {
        assertEquals("Flagged", FlagToggle.systemFlagName(emptyList()))
        assertEquals("Flagged", FlagToggle.systemFlagName(listOf(todo)))
        assertEquals("Urgent", FlagToggle.systemFlagName(listOf(todo, system(label = "Urgent"))))
        assertEquals("Urgent", FlagToggle.systemFlagName(listOf(system(label = "Urgent", enabled = false))))
    }

    // --------------------------------------------------------------- words

    @Test
    fun `the built-in flag under its own name keeps the words it always had`() {
        val flag = FlagToggle(system())
        assertEquals(UiLabel.Fixed(R.string.add_flag), flag.title(isSet = false))
        assertEquals(UiLabel.Fixed(R.string.remove_flag), flag.title(isSet = true))
        // A recolor alone keeps them.
        assertEquals(UiLabel.Fixed(R.string.add_flag), FlagToggle(system(color = "red")).title(isSet = false))
    }

    @Test
    fun `any other flag is named, the built-in one included once renamed`() {
        val urgent = FlagToggle(system(label = "Urgent"))
        assertEquals(UiLabel.Verbatim("Urgent"), urgent.title(isSet = false))
        assertEquals(UiLabel.Formatted(R.string.remove_named_flag, "Urgent"), urgent.title(isSet = true))
        assertEquals(UiLabel.Verbatim("Todo"), FlagToggle(todo).title(isSet = false))
        assertEquals(UiLabel.Formatted(R.string.remove_named_flag, "Todo"), FlagToggle(todo).title(isSet = true))
        // A flag of the user's own that happens to be called "Flagged" is
        // still named: only the built-in flag has the classic words.
        assertEquals(UiLabel.Verbatim("Flagged"), FlagToggle(todo.copy(label = "Flagged")).title(isSet = false))
    }

    @Test
    fun `whether a message carries the flag`() {
        assertTrue(FlagToggle(todo).isSetIn(listOf("\\Seen", "cabal-flag-01")))
        assertFalse(FlagToggle(todo).isSetIn(listOf("\\Seen", "\\Flagged")))
        assertTrue(FlagToggle(system()).isSetIn(listOf("\\Flagged")))
        // As `Envelope.isFlagged` reads the server's atom.
        assertTrue(FlagToggle(system()).isSetIn(listOf("\\flagged")))
        assertFalse(FlagToggle(system()).isSetIn(listOf("cabal-flag-01")))
    }

    // ---------------------------------------------------------- flag menus

    @Test
    fun `a flag menu lists every enabled flag in list order, the built-in one included`() {
        val palette = listOf(todo, system(label = "Urgent", color = "red"), later)
        assertEquals(
            listOf(
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Urgent", "red", isOn = true),
            ),
            FlagMenu.rows(palette, flags = listOf("\\Seen", "\\Flagged")),
        )
        // An untouched palette with flags of the user's own: the built-in
        // flag leads.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-01"),
            FlagMenu.rows(listOf(todo, later), flags = emptyList()).map { it.slot },
        )
    }

    @Test
    fun `a flag the message carries whose entry is disabled or deleted stays removable`() {
        val palette = listOf(todo, later)
        assertEquals(
            listOf(
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = false),
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
                FlagMenuRow("cabal-flag-02", "Later", "teal", isOn = true),
                FlagMenuRow("cabal-flag-09", "cabal-flag-09", "", isOn = true),
            ),
            FlagMenu.rows(palette, flags = listOf("cabal-flag-09", "cabal-flag-02")),
        )
        // The built-in flag too, once its entry is disabled: not offered,
        // but removable from a message that has it.
        val disabled = listOf(system(label = "Urgent", enabled = false), todo)
        assertEquals(listOf("cabal-flag-01"), FlagMenu.rows(disabled, flags = emptyList()).map { it.slot })
        assertEquals(
            listOf(
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Urgent", "yellow", isOn = true),
            ),
            FlagMenu.rows(disabled, flags = listOf("\\Flagged")),
        )
        // An untagged disabled flag is not offered.
        assertFalse(FlagMenu.rows(palette, flags = emptyList()).any { it.slot == "cabal-flag-02" })
    }

    @Test
    fun `a menu of only the default flag is recognized, so an untouched palette keeps its plain item`() {
        val untouched = FlagMenu.rows(emptyList(), flags = listOf("\\Flagged"))
        assertEquals(listOf(FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = true)), untouched)
        assertTrue(FlagMenu.isOnlyTheDefault(untouched, emptyList()))
        // A second flag, or a stray tag, makes it a list.
        assertFalse(FlagMenu.isOnlyTheDefault(FlagMenu.rows(listOf(todo), emptyList()), listOf(todo)))
        assertFalse(
            FlagMenu.isOnlyTheDefault(FlagMenu.rows(emptyList(), listOf("cabal-flag-09")), emptyList()),
        )
        // A lone stray row is not the default flag: with every flag
        // disabled there is no default, and the row is there to remove it.
        val noDefault = listOf(system(enabled = false))
        val stray = FlagMenu.rows(noDefault, flags = listOf("\\Flagged"))
        assertEquals(1, stray.size)
        assertFalse(FlagMenu.isOnlyTheDefault(stray, noDefault))
        assertEquals(emptyList<FlagMenuRow>(), FlagMenu.rows(noDefault, flags = emptyList()))
    }
}
