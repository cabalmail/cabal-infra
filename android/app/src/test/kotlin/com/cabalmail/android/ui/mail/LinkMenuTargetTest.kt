package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** Mirrors the Apple clients' `LinkMenuTargetTests` so the two readers gate identically. */
class LinkMenuTargetTest {
    @Test
    fun `web links parse and pick the browser label`() {
        val target = LinkMenuTarget.from("https://example.com/page?a=1#frag")
        assertEquals("https", target?.scheme)
        assertTrue(target!!.isWebLink)
        assertEquals("https://example.com/page?a=1#frag", target.url)
    }

    @Test
    fun `scheme matching is case-insensitive`() {
        val target = LinkMenuTarget.from("HTTPS://example.com")
        assertEquals("https", target?.scheme)
        assertTrue(target!!.isWebLink)
    }

    @Test
    fun `mailto parses but is not a web link`() {
        val target = LinkMenuTarget.from("mailto:someone@sub.example.com")
        assertEquals("mailto", target?.scheme)
        assertFalse(target!!.isWebLink)
    }

    @Test
    fun `executable and local schemes are rejected`() {
        val blocked =
            listOf(
                "javascript:alert(1)",
                "vbscript:msgbox(1)",
                "data:text/html,<script>alert(1)</script>",
                "blob:https://example.com/uuid",
                "file:///etc/passwd",
                "about:blank",
                "intent://scan/#Intent;scheme=zxing;end",
                "content://com.android.contacts/data",
            )
        blocked.forEach { url ->
            assertNull(LinkMenuTarget.from(url), "expected $url to be rejected")
        }
    }

    @Test
    fun `scheme-less and malformed hrefs are rejected`() {
        assertNull(LinkMenuTarget.from("example.com/page"))
        assertNull(LinkMenuTarget.from("/relative/path"))
        assertNull(LinkMenuTarget.from("#fragment"))
        assertNull(LinkMenuTarget.from(""))
        assertNull(LinkMenuTarget.from("   "))
        assertNull(LinkMenuTarget.from(null))
    }

    @Test
    fun `surrounding whitespace is trimmed`() {
        val target = LinkMenuTarget.from("  https://example.com  ")
        assertEquals("https://example.com", target?.url)
    }
}
