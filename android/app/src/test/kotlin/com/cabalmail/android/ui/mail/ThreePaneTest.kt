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

    @Test
    fun `message panes split what a resized folder pane leaves`() {
        assertEquals(220.dp, threePaneListWidth(740.dp, 300.dp))
    }

    @Test
    fun `folder pane drags between its floor and room for both message panes`() {
        assertEquals(250.dp, clampSidePaneWidth(250.dp, 1000.dp))
        assertEquals(SIDE_PANE_MIN_WIDTH, clampSidePaneWidth(40.dp, 1000.dp))
        assertEquals(1000.dp - MESSAGE_PANE_MIN_WIDTH * 2, clampSidePaneWidth(900.dp, 1000.dp))
        // The narrowest three-pane window only has room for the default.
        assertEquals(FOLDER_PANE_WIDTH, clampSidePaneWidth(400.dp, THREE_PANE_MIN_WIDTH))
        // A stored width wider than the window allows is clamped, not lost:
        // the same request fits again in a wider window.
        assertEquals(400.dp, clampSidePaneWidth(400.dp, 1200.dp))
    }

    @Test
    fun `list pane leaves the reader at least the message-pane floor`() {
        assertEquals(300.dp, clampListPaneWidth(300.dp, 800.dp, 24.dp))
        assertEquals(MESSAGE_PANE_MIN_WIDTH, clampListPaneWidth(0.dp, 800.dp, 24.dp))
        assertEquals(800.dp - 24.dp - MESSAGE_PANE_MIN_WIDTH, clampListPaneWidth(800.dp, 800.dp, 24.dp))
        // Too narrow for both floors: the list keeps its own.
        assertEquals(MESSAGE_PANE_MIN_WIDTH, clampListPaneWidth(300.dp, 400.dp, 24.dp))
    }
}
