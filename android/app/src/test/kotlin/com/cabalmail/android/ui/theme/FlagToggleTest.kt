package com.cabalmail.android.ui.theme

import com.cabalmail.android.R
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
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
    private val later = FlagPaletteEntry(slot = "cabal-flag-02", label = "Later", color = "teal")

    private fun system(
        label: String = "Flagged",
        color: String = "yellow",
    ) = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = color)

    /**
     * A palette as a build from before the Enabled switch was removed
     * stored it: "Later" first and switched off, the built-in flag renamed
     * and switched off, then "Todo".
     */
    private val olderBuildPalette =
        FlagPalette.decode(
            """[{"slot":"cabal-flag-02","label":"Later","color":"teal","enabled":false},""" +
                """{"slot":"\\Flagged","label":"Urgent","color":"red","enabled":false},""" +
                """{"slot":"cabal-flag-01","label":"Todo","color":"blue"}]""",
        )!!

    // ---------------------------------------------------------- which flag

    @Test
    fun `mail's controls act on the first entry`() {
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.defaultFlag(emptyList()))
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.defaultFlag(listOf(todo)))
        assertEquals(FlagToggle("cabal-flag-01", "Todo", "blue"), FlagToggle.defaultFlag(listOf(todo, system())))
        // A flag an older build switched off is a flag like any other:
        // first in the list, it is the default. It used to be passed over.
        assertEquals(FlagToggle("cabal-flag-02", "Later", "teal"), FlagToggle.defaultFlag(olderBuildPalette))
    }

    @Test
    fun `the feed's controls act on the built-in entry wherever it sits`() {
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"), FlagToggle.systemFlag(listOf(todo)))
        assertEquals(
            FlagToggle(FlagPalette.SYSTEM_SLOT, "Urgent", "red"),
            FlagToggle.systemFlag(listOf(todo, system(label = "Urgent", color = "red"))),
        )
        // Switched off by an older build, it is still the feed's flag. The
        // feed's swipe, star and pill used to go away on such a palette.
        assertEquals(FlagToggle(FlagPalette.SYSTEM_SLOT, "Urgent", "red"), FlagToggle.systemFlag(olderBuildPalette))
    }

    @Test
    fun `the filters take the built-in flag's name`() {
        assertEquals("Flagged", FlagToggle.systemFlagName(emptyList()))
        assertEquals("Flagged", FlagToggle.systemFlagName(listOf(todo)))
        assertEquals("Urgent", FlagToggle.systemFlagName(listOf(todo, system(label = "Urgent"))))
        assertEquals("Urgent", FlagToggle.systemFlagName(olderBuildPalette))
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
    fun `a flag menu lists every flag in list order, the built-in one included`() {
        val palette = listOf(todo, system(label = "Urgent", color = "red"), later)
        assertEquals(
            listOf(
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Urgent", "red", isOn = true),
                FlagMenuRow("cabal-flag-02", "Later", "teal", isOn = false),
            ),
            FlagMenu.rows(palette, flags = listOf("\\Seen", "\\Flagged")),
        )
        // An untouched palette with flags of the user's own: the built-in
        // flag leads.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-01", "cabal-flag-02"),
            FlagMenu.rows(listOf(todo, later), flags = emptyList()).map { it.slot },
        )
    }

    @Test
    fun `a flag an older build switched off is offered like any other`() {
        // Carried by nothing: offered, unchecked. It used to be left out.
        assertEquals(
            listOf(
                FlagMenuRow("cabal-flag-02", "Later", "teal", isOn = false),
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Urgent", "red", isOn = false),
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
            ),
            FlagMenu.rows(olderBuildPalette, flags = emptyList()),
        )
        // Carried: checked in its own place in the list. It used to be
        // moved after the list, as a tag that could only be removed.
        assertEquals(
            listOf("cabal-flag-02" to true, FlagPalette.SYSTEM_SLOT to true, "cabal-flag-01" to false),
            FlagMenu.rows(olderBuildPalette, flags = listOf("\\Flagged", "cabal-flag-02")).map { it.slot to it.isOn },
        )
    }

    @Test
    fun `a flag the message carries whose entry was deleted stays removable`() {
        val palette = listOf(todo)
        // Named by its slot id and gray, having no entry; after the list.
        assertEquals(
            listOf(
                FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = false),
                FlagMenuRow("cabal-flag-01", "Todo", "blue", isOn = false),
                FlagMenuRow("cabal-flag-09", "cabal-flag-09", "", isOn = true),
            ),
            FlagMenu.rows(palette, flags = listOf("cabal-flag-09")),
        )
        // Two of them come in slot order.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-01", "cabal-flag-05", "cabal-flag-09"),
            FlagMenu.rows(palette, flags = listOf("cabal-flag-09", "cabal-flag-05")).map { it.slot },
        )
        // A deleted flag that the message does not carry is not offered.
        assertFalse(FlagMenu.rows(palette, flags = emptyList()).any { it.slot == "cabal-flag-09" })
    }

    @Test
    fun `a menu of only the default flag is recognized, so an untouched palette keeps its plain item`() {
        val untouched = FlagMenu.rows(emptyList(), flags = listOf("\\Flagged"))
        assertEquals(listOf(FlagMenuRow(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow", isOn = true)), untouched)
        assertTrue(FlagMenu.isOnlyTheDefault(untouched, emptyList()))
        // The row is there whether or not the message is flagged.
        assertTrue(FlagMenu.isOnlyTheDefault(FlagMenu.rows(emptyList(), flags = emptyList()), emptyList()))
        // A second flag, or a stray tag, makes it a list.
        assertFalse(FlagMenu.isOnlyTheDefault(FlagMenu.rows(listOf(todo), emptyList()), listOf(todo)))
        assertFalse(
            FlagMenu.isOnlyTheDefault(FlagMenu.rows(emptyList(), listOf("cabal-flag-09")), emptyList()),
        )
        // A palette whose one entry an older build switched off has the
        // same single row: there is always a default flag now.
        val allOff =
            FlagPalette.decode("""[{"slot":"\\Flagged","label":"Flagged","color":"yellow","enabled":false}]""")!!
        assertTrue(FlagMenu.isOnlyTheDefault(FlagMenu.rows(allOff, flags = listOf("\\Flagged")), allOff))
        assertEquals(1, FlagMenu.rows(allOff, flags = emptyList()).size)
    }
}
