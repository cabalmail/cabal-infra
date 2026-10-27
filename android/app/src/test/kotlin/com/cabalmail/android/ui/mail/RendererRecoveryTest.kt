package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What the mail reader and the feed article view do when Android ends
 * their WebView's render process. An unclaimed event kills the app, so
 * every path claims it; a reclaimed renderer always gets a fresh view; a
 * crashing one gets one silent remount, then the notice.
 */
class RendererRecoveryTest {
    @Test
    fun `the event is always claimed`() {
        val recovery = RendererRecovery()
        assertTrue(recovery.onRenderProcessGone(didCrash = false))
        assertTrue(recovery.onRenderProcessGone(didCrash = true))
        assertTrue(recovery.onRenderProcessGone(didCrash = true))
        assertTrue(recovery.gaveUp, "the third loss came after the silent remount")
    }

    @Test
    fun `a reclaimed renderer is remounted every time`() {
        val recovery = RendererRecovery()
        repeat(3) { recovery.onRenderProcessGone(didCrash = false) }
        assertEquals(3, recovery.generation)
        assertFalse(recovery.gaveUp)
    }

    @Test
    fun `a crashed renderer is remounted once, then the notice shows`() {
        val recovery = RendererRecovery()
        recovery.onRenderProcessGone(didCrash = true)
        assertEquals(1, recovery.generation)
        assertFalse(recovery.gaveUp)

        recovery.onRenderProcessGone(didCrash = true)
        assertTrue(recovery.gaveUp)
        assertEquals(1, recovery.generation, "giving up mounts no new view")
    }

    @Test
    fun `reclaims do not spend the crash's silent remount`() {
        val recovery = RendererRecovery()
        recovery.onRenderProcessGone(didCrash = false)
        recovery.onRenderProcessGone(didCrash = false)
        recovery.onRenderProcessGone(didCrash = true)
        assertFalse(recovery.gaveUp)
        assertEquals(3, recovery.generation)
    }

    @Test
    fun `retry mounts a fresh view and a further crash shows the notice again`() {
        val recovery = RendererRecovery()
        recovery.onRenderProcessGone(didCrash = true)
        recovery.onRenderProcessGone(didCrash = true)

        recovery.retry()
        assertFalse(recovery.gaveUp)
        assertEquals(2, recovery.generation)

        // Each further attempt is the reader's tap, never an automatic loop.
        recovery.onRenderProcessGone(didCrash = true)
        assertTrue(recovery.gaveUp)
        assertEquals(2, recovery.generation)
    }

    @Test
    fun `retry is a no-op while the view is up`() {
        val recovery = RendererRecovery()
        recovery.retry()
        assertEquals(0, recovery.generation)
        assertFalse(recovery.gaveUp)
    }
}
