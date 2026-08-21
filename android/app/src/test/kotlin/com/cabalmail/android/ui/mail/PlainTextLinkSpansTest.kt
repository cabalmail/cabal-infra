package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PlainTextLinkSpansTest {
    @Test
    fun `a bare url is detected with exact bounds`() {
        val text = "Visit https://example.com/page today"
        val spans = plainTextLinkSpans(text)
        assertEquals(1, spans.size)
        assertEquals("https://example.com/page", spans[0].url)
        assertEquals("https://example.com/page", text.substring(spans[0].start, spans[0].end))
    }

    @Test
    fun `trailing sentence punctuation stays out of the link`() {
        val spans = plainTextLinkSpans("Read https://example.com/a, then https://example.com/b.")
        assertEquals(listOf("https://example.com/a", "https://example.com/b"), spans.map { it.url })
    }

    @Test
    fun `angle brackets around a url stay out of the link`() {
        val spans = plainTextLinkSpans("Confirm here: <https://example.com/confirm?t=1>")
        assertEquals(listOf("https://example.com/confirm?t=1"), spans.map { it.url })
    }

    @Test
    fun `a closing paren is kept only when the url opened one`() {
        val wrapped = plainTextLinkSpans("(see https://example.com/page)")
        assertEquals("https://example.com/page", wrapped.single().url)
        val wiki = plainTextLinkSpans("https://example.com/wiki/Foo_(bar)")
        assertEquals("https://example.com/wiki/Foo_(bar)", wiki.single().url)
    }

    @Test
    fun `www hosts get an https prefix`() {
        val spans = plainTextLinkSpans("More at www.example.com/deals")
        assertEquals("https://www.example.com/deals", spans.single().url)
    }

    @Test
    fun `a bare www word without a further dot is prose`() {
        assertTrue(plainTextLinkSpans("the www.internet is vast").none { "internet" in it.url })
    }

    @Test
    fun `email addresses become mailto targets`() {
        val spans = plainTextLinkSpans("Write to support@help.example.com for help")
        assertEquals("mailto:support@help.example.com", spans.single().url)
    }

    @Test
    fun `an address inside a url is not double-matched`() {
        val spans = plainTextLinkSpans("https://example.com/unsubscribe?user=a@b.example.com")
        assertEquals(1, spans.size)
        assertEquals("https://example.com/unsubscribe?user=a@b.example.com", spans[0].url)
    }

    @Test
    fun `a www host inside a full url is not double-matched`() {
        val spans = plainTextLinkSpans("https://www.example.com/page")
        assertEquals(listOf("https://www.example.com/page"), spans.map { it.url })
    }

    @Test
    fun `a scheme with nothing after it is ignored`() {
        assertTrue(plainTextLinkSpans("broken link: https:// oops").isEmpty())
    }

    @Test
    fun `plain prose yields no spans`() {
        assertTrue(plainTextLinkSpans("Nothing to see here. Really, nothing.").isEmpty())
    }

    @Test
    fun `spans come back in document order`() {
        val text = "a@b.example.com then https://example.com then www.example.org"
        val spans = plainTextLinkSpans(text)
        assertEquals(
            listOf("mailto:a@b.example.com", "https://example.com", "https://www.example.org"),
            spans.map { it.url },
        )
        assertTrue(spans.zipWithNext().all { (a, b) -> a.end <= b.start })
    }
}
