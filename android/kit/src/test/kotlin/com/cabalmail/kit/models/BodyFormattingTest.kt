package com.cabalmail.kit.models

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BodyFormattingTest {
    @Test
    fun `finds cids across quote styles and case`() {
        val html =
            """<img src="cid:logo@example"> <IMG SRC='cid:photo.png'> <img src = "cid:logo@example">"""
        assertEquals(listOf("logo@example", "photo.png"), inlineContentIds(html))
    }

    @Test
    fun `html without cids yields nothing`() {
        assertEquals(emptyList<String>(), inlineContentIds("""<img src="https://example.com/x.png">"""))
    }

    @Test
    fun `resolves known cids and leaves unknown ones alone`() {
        val html = """<img src="cid:known"><img src="cid:unknown">"""
        val resolved = resolveInlineImages(html, mapOf("known" to "data:image/png;base64,AAAA"))
        assertEquals("""<img src="data:image/png;base64,AAAA"><img src="cid:unknown">""", resolved)
    }

    @Test
    fun `reader mode keeps content and swaps palette with dark mode`() {
        val html = "<p>Hello</p>"
        val light = readerModeHtml(html, darkMode = false)
        val dark = readerModeHtml(html, darkMode = true)
        assertTrue(light.contains(html))
        assertTrue(dark.contains(html))
        assertTrue(light.contains("!important"))
        assertNotEquals(light, dark)
    }

    @Test
    fun `reader mode strips author style blocks including mobile media queries`() {
        val html =
            """
            <html><head>
            <STYLE type="text/css">
              @media (max-width: 600px) { .wrapper { background: #ffffff !important; } }
            </STYLE>
            </head><body><div class="wrapper"><p>Hello</p></div></body></html>
            """.trimIndent()
        val out = readerModeHtml(html, darkMode = true)
        assertFalse(out.contains("max-width: 600px"))
        assertFalse(out.contains("#ffffff"))
        assertTrue(out.contains("""<div class="wrapper"><p>Hello</p></div>"""))
        // The reader's own trailing stylesheet must survive the strip.
        assertTrue(out.contains("!important"))
    }

    @Test
    fun `reader mode strips stylesheet links but keeps other links and inline styles`() {
        val html =
            """
            <link rel="stylesheet" href="https://example.com/mail.css">
            <link rel=icon href="https://example.com/favicon.ico">
            <p style="color: #333333">Hello</p>
            """.trimIndent()
        val out = readerModeHtml(html, darkMode = false)
        assertFalse(out.contains("mail.css"))
        assertTrue(out.contains("favicon.ico"))
        assertTrue(out.contains("""<p style="color: #333333">Hello</p>"""))
    }
}
