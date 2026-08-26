package com.cabalmail.android.navigation

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class CursorNavigationTest {
    @Test
    fun `a cursor open never reuses the list entry it finds`() {
        // #1289: every folder shares the messages destination, so reaching a
        // new one on launchSingleTop alone left the entry's view model (list,
        // pills) on INBOX while the title moved. Whatever the cursor names,
        // the plan rewinds first.
        listOf("Archive", "Sent", "INBOX").forEach { folder ->
            assertEquals(MAIL_HUB_ROUTE, cursorNavigation(folder, null, compactWidth = true).popUpTo)
            assertEquals(MAIL_HUB_ROUTE, cursorNavigation(folder, 243L, compactWidth = true).popUpTo)
            assertEquals(MAIL_HUB_ROUTE, cursorNavigation(folder, 243L, compactWidth = false).popUpTo)
        }
    }

    @Test
    fun `a phone cursor pushes the reader above the list`() {
        val plan = cursorNavigation("Archive", 243L, compactWidth = true)

        assertEquals("messages/Archive", plan.listRoute)
        assertEquals("message/Archive/243", plan.readerRoute)
    }

    @Test
    fun `a wide-window cursor carries the uid on the list route instead`() {
        val plan = cursorNavigation("Archive", 243L, compactWidth = false)

        assertEquals("messages/Archive?uid=243", plan.listRoute)
        assertNull(plan.readerRoute)
    }

    @Test
    fun `a folder-only cursor opens no reader on either width`() {
        assertNull(cursorNavigation("Sent", null, compactWidth = true).readerRoute)
        assertNull(cursorNavigation("Sent", null, compactWidth = false).readerRoute)
        // A cursor with no message selected stores 0, not null.
        assertNull(cursorNavigation("Sent", 0L, compactWidth = true).readerRoute)
        assertEquals("messages/Sent", cursorNavigation("Sent", 0L, compactWidth = false).listRoute)
    }

    @Test
    fun `the folder rides the route already encoded`() {
        // Uri.encode is the caller's job (it is unavailable off-device), so a
        // folder with a separator in it must arrive escaped and stay that way.
        val plan = cursorNavigation("Archive%2F2026", 9L, compactWidth = true)

        assertEquals("messages/Archive%2F2026", plan.listRoute)
        assertEquals("message/Archive%2F2026/9", plan.readerRoute)
        assertNotNull(plan.popUpTo)
    }
}
