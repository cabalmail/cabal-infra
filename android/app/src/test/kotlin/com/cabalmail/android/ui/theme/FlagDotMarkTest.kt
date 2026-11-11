package com.cabalmail.android.ui.theme

import com.cabalmail.android.ui.feeds.feedRowDescription
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * What a row and the reader's header draw for the flags an item carries
 * (unified-flags plan, decision 4): one mark per flag, the built-in flag
 * included, in the order of Settings > Flags, under the palette's names and
 * colors. The Kotlin sibling of the Apple app's `FlagDotMarkTests`.
 */
class FlagDotMarkTest {
    private val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
    private val waiting = FlagPaletteEntry(slot = "cabal-flag-02", label = "Waiting", color = "blue", enabled = false)

    private fun system(
        label: String = "Flagged",
        color: String = "yellow",
        enabled: Boolean = true,
    ) = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = color, enabled = enabled)

    @Test
    fun `a flagged message gets the default entry's mark from a palette that stores none`() {
        // An untouched account: the star's place is taken by a dot in the
        // same gold, named as the star was.
        assertEquals(
            listOf(FlagDotMark(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow")),
            FlagDotMark.marks(listOf("\\Seen", "\\Flagged"), emptyList()),
        )
        assertEquals(emptyList<FlagDotMark>(), FlagDotMark.marks(listOf("\\Seen"), emptyList()))
    }

    @Test
    fun `a stored entry gives the mark its name and color`() {
        assertEquals(
            listOf(FlagDotMark(FlagPalette.SYSTEM_SLOT, "Urgent", "red")),
            FlagDotMark.marks(listOf("\\Flagged"), listOf(system(label = "Urgent", color = "red"))),
        )
    }

    @Test
    fun `marks follow the palette's order`() {
        val flags = listOf("cabal-flag-01", "\\Flagged")
        // Untouched: the built-in flag leads.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-01"),
            FlagDotMark.marks(flags, listOf(urgent)).map { it.slot },
        )
        // Another flag moved above it leads instead.
        assertEquals(
            listOf("cabal-flag-01", FlagPalette.SYSTEM_SLOT),
            FlagDotMark.marks(flags, listOf(urgent, system())).map { it.slot },
        )
    }

    @Test
    fun `the row cap counts the built-in flag`() {
        val palette = (1..5).map { FlagPaletteEntry("cabal-flag-0$it", "F$it", "green") }
        val flags = listOf("\\Flagged") + palette.map { it.slot }
        val row = FlagDotMark.marks(flags, palette)
        assertEquals(FlagDotMark.ROW_LIMIT, row.size)
        assertEquals(FlagPalette.SYSTEM_SLOT, row.first().slot)
        assertEquals("cabal-flag-03", row.last().slot)
        // The reader's chips ask for all of them.
        assertEquals(6, FlagDotMark.marks(flags, palette, limit = Int.MAX_VALUE).size)
    }

    @Test
    fun `a disabled entry's tag is still drawn`() {
        // Disabled means offered nowhere, not hidden: the tag is on the
        // message and has to stay visible to be removed.
        assertEquals(
            listOf(
                FlagDotMark(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow"),
                FlagDotMark("cabal-flag-02", "Waiting", "blue"),
            ),
            FlagDotMark.marks(listOf("\\Flagged", "cabal-flag-02"), listOf(system(enabled = false), waiting)),
        )
    }

    @Test
    fun `a tag whose entry was deleted is named by its slot and draws gray`() {
        assertEquals(
            listOf(FlagDotMark("cabal-flag-09", "cabal-flag-09", "")),
            FlagDotMark.marks(listOf("cabal-flag-09"), listOf(urgent)),
        )
    }

    @Test
    fun `foreign keywords and other system flags are never marks`() {
        assertEquals(
            emptyList<FlagDotMark>(),
            FlagDotMark.marks(listOf("\\Seen", "\\Answered", "\$Forwarded", "cabal-flag-21"), listOf(urgent)),
        )
    }

    @Test
    fun `a feed item's one flag takes the built-in entry's name and color`() {
        assertEquals(emptyList<FlagDotMark>(), FlagDotMark.feedMarks(isFlagged = false, palette = listOf(urgent)))
        assertEquals(
            listOf(FlagDotMark(FlagPalette.SYSTEM_SLOT, "Flagged", "yellow")),
            FlagDotMark.feedMarks(isFlagged = true, palette = listOf(urgent)),
        )
        // Wherever the entry sits in the list, and whatever it is called.
        assertEquals(
            listOf(FlagDotMark(FlagPalette.SYSTEM_SLOT, "Later", "teal")),
            FlagDotMark.feedMarks(isFlagged = true, palette = listOf(urgent, system(label = "Later", color = "teal"))),
        )
    }

    @Test
    fun `the feed row names its flag after the date`() {
        assertEquals(
            "Unread, Title, First line, 2h, Later",
            feedRowDescription(
                unread = "Unread",
                title = "Title",
                snippet = "First line",
                date = "2h",
                flags = listOf("Later"),
            ),
        )
        // Empty parts leave no stray separators, and a read, unflagged item
        // says what it always said.
        assertEquals(
            "Title, 2h",
            feedRowDescription(unread = null, title = "Title", snippet = "", date = "2h", flags = emptyList()),
        )
    }
}
