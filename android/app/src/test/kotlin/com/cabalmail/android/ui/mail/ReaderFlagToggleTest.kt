package com.cabalmail.android.ui.mail

import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.FlagToggle
import com.cabalmail.android.ui.theme.UiLabel
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

/**
 * The reader's flag toggle (#1607): its label and glyph follow the message's
 * state. Before, both states read "Flagged" and drew the same solid star.
 * Since the unified-flags work it toggles the default flag, under that
 * flag's name and in its color.
 */
class ReaderFlagToggleTest {
    private val builtIn = FlagToggle.defaultFlag(emptyList())

    @Test
    fun `an unflagged message offers to flag it and draws a hollow star`() {
        assertEquals(
            ReaderFlagToggle(label = UiLabel.Fixed(R.string.add_flag), filledStar = false, color = "yellow"),
            readerFlagToggle(builtIn, isSet = false),
        )
    }

    @Test
    fun `a flagged message offers to remove the flag and draws a filled star`() {
        assertEquals(
            ReaderFlagToggle(label = UiLabel.Fixed(R.string.remove_flag), filledStar = true, color = "yellow"),
            readerFlagToggle(builtIn, isSet = true),
        )
    }

    @Test
    fun `the two states differ in both label and glyph`() {
        val off = readerFlagToggle(builtIn, isSet = false)
        val on = readerFlagToggle(builtIn, isSet = true)
        assertNotEquals(off.label, on.label)
        assertNotEquals(off.filledStar, on.filledStar)
    }

    @Test
    fun `another default flag gives the button its name and color`() {
        val todo = FlagToggle(FlagPaletteEntry(slot = "cabal-flag-01", label = "Todo", color = "blue"))
        assertEquals(
            ReaderFlagToggle(label = UiLabel.Verbatim("Todo"), filledStar = false, color = "blue"),
            readerFlagToggle(todo, isSet = false),
        )
        assertEquals(
            ReaderFlagToggle(
                label = UiLabel.Formatted(R.string.remove_named_flag, "Todo"),
                filledStar = true,
                color = "blue",
            ),
            readerFlagToggle(todo, isSet = true),
        )
    }
}
