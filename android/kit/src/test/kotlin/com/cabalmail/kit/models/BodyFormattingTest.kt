package com.cabalmail.kit.models

import org.junit.jupiter.api.Assertions.assertEquals
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
}
