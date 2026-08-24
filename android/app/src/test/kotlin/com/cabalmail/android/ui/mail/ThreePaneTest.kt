package com.cabalmail.android.ui.mail

import androidx.compose.ui.unit.dp
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ThreePaneTest {
    @Test
    fun `folder pane needs room for two usable message panes`() {
        assertFalse(fitsThreePanes(THREE_PANE_MIN_WIDTH - 1.dp))
        assertTrue(fitsThreePanes(THREE_PANE_MIN_WIDTH))
        // A Galaxy S10 class phone in landscape (~740dp of content beside
        // the navigation rail) gets all three panes.
        assertTrue(fitsThreePanes(740.dp))
        // A phone in portrait never comes close (compact widths do not
        // reach this screen at all; this is the belt to that suspender).
        assertFalse(fitsThreePanes(411.dp))
    }

    @Test
    fun `message panes split what the folder pane leaves evenly`() {
        assertEquals(270.dp, threePaneListWidth(740.dp))
        assertEquals((THREE_PANE_MIN_WIDTH - FOLDER_PANE_WIDTH) / 2, threePaneListWidth(THREE_PANE_MIN_WIDTH))
    }
}
