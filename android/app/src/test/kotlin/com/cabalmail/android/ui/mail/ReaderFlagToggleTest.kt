package com.cabalmail.android.ui.mail

import com.cabalmail.android.R
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

/**
 * The reader's flag toggle (#1607): its label and glyph follow the message's
 * state. Before, both states read "Flagged" and drew the same solid star.
 */
class ReaderFlagToggleTest {
    @Test
    fun `an unflagged message offers to flag it and draws a hollow star`() {
        assertEquals(ReaderFlagToggle(label = R.string.add_flag, filledStar = false), readerFlagToggle(false))
    }

    @Test
    fun `a flagged message offers to remove the flag and draws a filled star`() {
        assertEquals(ReaderFlagToggle(label = R.string.remove_flag, filledStar = true), readerFlagToggle(true))
    }

    @Test
    fun `the two states differ in both label and glyph`() {
        val off = readerFlagToggle(false)
        val on = readerFlagToggle(true)
        assertNotEquals(off.label, on.label)
        assertNotEquals(off.filledStar, on.filledStar)
        // The constant the reader used to pass in both states.
        assertNotEquals(R.string.flagged, off.label)
    }
}
