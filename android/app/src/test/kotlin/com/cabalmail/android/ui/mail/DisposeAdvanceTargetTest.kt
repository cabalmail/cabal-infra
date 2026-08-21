package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.settings.DisposeAdvance
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * Mirrors the Apple clients' `DisposeAdvanceTests` so both readers advance
 * identically. Fixtures are newest-first (index 0 = newest); `seen` marks a
 * read row.
 */
class DisposeAdvanceTargetTest {
    private fun rows(vararg specs: Pair<Long, Boolean>): List<Envelope> =
        specs.map { (uid, seen) ->
            Envelope(id = uid, flags = if (seen) listOf("\\Seen") else emptyList())
        }

    @Test
    fun `next returns the row below regardless of read state`() {
        val window = rows(5L to false, 4L to false, 3L to true, 2L to false)
        assertEquals(3L, disposeAdvanceTarget(window, 4L, DisposeAdvance.NEXT)?.id)
    }

    @Test
    fun `next from the bottom row falls back to the row above`() {
        val window = rows(5L to false, 4L to false, 3L to false)
        assertEquals(4L, disposeAdvanceTarget(window, 3L, DisposeAdvance.NEXT)?.id)
    }

    @Test
    fun `next with no other rows returns null`() {
        assertNull(disposeAdvanceTarget(rows(5L to false), 5L, DisposeAdvance.NEXT))
    }

    @Test
    fun `next unread skips read rows below`() {
        val window = rows(5L to false, 4L to true, 3L to true, 2L to false)
        assertEquals(2L, disposeAdvanceTarget(window, 5L, DisposeAdvance.NEXT_UNREAD)?.id)
    }

    @Test
    fun `next unread falls back to the nearest unread above`() {
        val window = rows(5L to false, 4L to true, 3L to false, 2L to true)
        assertEquals(5L, disposeAdvanceTarget(window, 3L, DisposeAdvance.NEXT_UNREAD)?.id)
    }

    @Test
    fun `previous unread returns the nearest unread above`() {
        val window = rows(5L to false, 4L to true, 3L to false, 2L to false)
        assertEquals(5L, disposeAdvanceTarget(window, 3L, DisposeAdvance.PREVIOUS_UNREAD)?.id)
    }

    @Test
    fun `previous unread falls back to the nearest unread below`() {
        val window = rows(5L to true, 4L to true, 3L to false, 2L to false)
        assertEquals(2L, disposeAdvanceTarget(window, 3L, DisposeAdvance.PREVIOUS_UNREAD)?.id)
    }

    @Test
    fun `previous unread with no other unread returns null`() {
        val window = rows(5L to true, 4L to true, 3L to false)
        assertNull(disposeAdvanceTarget(window, 3L, DisposeAdvance.PREVIOUS_UNREAD))
    }

    @Test
    fun `first unread returns the topmost unread`() {
        val window = rows(5L to true, 4L to false, 3L to false, 2L to false)
        assertEquals(4L, disposeAdvanceTarget(window, 3L, DisposeAdvance.FIRST_UNREAD)?.id)
    }

    @Test
    fun `first unread skips the disposed message itself`() {
        val window = rows(5L to false, 4L to true, 3L to false)
        assertEquals(3L, disposeAdvanceTarget(window, 5L, DisposeAdvance.FIRST_UNREAD)?.id)
    }

    @Test
    fun `first unread with no other unread returns null`() {
        val window = rows(5L to false, 4L to true, 3L to true)
        assertNull(disposeAdvanceTarget(window, 5L, DisposeAdvance.FIRST_UNREAD))
    }

    @Test
    fun `a disposed row missing from the window walks from the top`() {
        val window = rows(5L to true, 4L to false, 3L to false)
        assertEquals(5L, disposeAdvanceTarget(window, 99L, DisposeAdvance.NEXT)?.id)
        assertEquals(4L, disposeAdvanceTarget(window, 99L, DisposeAdvance.NEXT_UNREAD)?.id)
        assertEquals(4L, disposeAdvanceTarget(window, 99L, DisposeAdvance.PREVIOUS_UNREAD)?.id)
    }

    @Test
    fun `the golden case follows every policy`() {
        // [6, 5(seen), 4, 3(seen), 2], disposing 4 — matches the Apple test.
        val window = rows(6L to false, 5L to true, 4L to false, 3L to true, 2L to false)
        assertEquals(3L, disposeAdvanceTarget(window, 4L, DisposeAdvance.NEXT)?.id)
        assertEquals(2L, disposeAdvanceTarget(window, 4L, DisposeAdvance.NEXT_UNREAD)?.id)
        assertEquals(6L, disposeAdvanceTarget(window, 4L, DisposeAdvance.PREVIOUS_UNREAD)?.id)
        assertEquals(6L, disposeAdvanceTarget(window, 4L, DisposeAdvance.FIRST_UNREAD)?.id)
    }
}
