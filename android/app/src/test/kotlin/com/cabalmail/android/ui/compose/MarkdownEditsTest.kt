package com.cabalmail.android.ui.compose

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class MarkdownEditsTest {
    @Test
    fun `bold wraps the selection and keeps it selected`() {
        val out = MarkdownEdits.apply(MarkdownAction.BOLD, TextSelection("say hello now", 4, 9))
        assertEquals("say **hello** now", out.text)
        assertEquals("hello", out.text.substring(out.start, out.end))
    }

    @Test
    fun `inline actions insert a selected placeholder when nothing is selected`() {
        val out = MarkdownEdits.apply(MarkdownAction.ITALIC, TextSelection("ab", 1, 1))
        assertEquals("a_italic_b", out.text)
        assertEquals("italic", out.text.substring(out.start, out.end))
    }

    @Test
    fun `link selects the url placeholder`() {
        val out = MarkdownEdits.apply(MarkdownAction.LINK, TextSelection("see docs", 4, 8))
        assertEquals("see [docs](https://)", out.text)
        assertEquals("https://", out.text.substring(out.start, out.end))
    }

    @Test
    fun `block actions prefix every touched line`() {
        val text = "intro\none\ntwo\nthree\nend"
        val start = text.indexOf("one") + 1
        val end = text.indexOf("three") + 2
        val bullets = MarkdownEdits.apply(MarkdownAction.BULLETS, TextSelection(text, start, end))
        assertEquals("intro\n- one\n- two\n- three\nend", bullets.text)
        val numbers = MarkdownEdits.apply(MarkdownAction.NUMBERS, TextSelection(text, start, end))
        assertEquals("intro\n1. one\n2. two\n3. three\nend", numbers.text)
        val quote = MarkdownEdits.apply(MarkdownAction.QUOTE, TextSelection("solo", 2, 2))
        assertEquals("> solo", quote.text)
        assertEquals(6, quote.start)
    }

    @Test
    fun `reversed selections are normalized`() {
        val out = MarkdownEdits.apply(MarkdownAction.CODE, TextSelection("x = 1", 5, 0))
        assertEquals("`x = 1`", out.text)
    }
}
