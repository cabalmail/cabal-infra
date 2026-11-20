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

    @Test
    fun `the upgrade-insecure-requests meta lands at the start of the head and never before a doctype`() {
        val meta = UPGRADE_INSECURE_REQUESTS_META
        assertEquals(
            "<html><head>$meta<title>x</title></head></html>",
            upgradeInsecureRequests("<html><head><title>x</title></head></html>"),
        )
        assertEquals("<!DOCTYPE html>$meta<p>x</p>", upgradeInsecureRequests("<!DOCTYPE html><p>x</p>"))
        assertEquals(
            "<html lang=\"en\">$meta<body/></html>",
            upgradeInsecureRequests("<html lang=\"en\"><body/></html>"),
        )
        assertEquals("$meta<p>x</p>", upgradeInsecureRequests("<p>x</p>"))
        val once = upgradeInsecureRequests(upgradeInsecureRequests("<p>x</p>"))
        assertEquals(1, once.windowed(meta.length).count { it == meta })
        assertTrue(upgradeInsecureRequests(readerModeHtml("<p>x</p>", darkMode = false)).contains(meta))
    }

    @Test
    fun `the article reader document leads with a policy that refuses script, plugins and frames`() {
        val policy = Regex("""^<meta http-equiv="Content-Security-Policy" content="([^"]*)">$""")
        val directives =
            policy
                .find(ARTICLE_READER_POLICY_META)
                ?.groupValues
                ?.get(1)
                ?.split(";")
                ?.map { it.trim() }
        assertEquals(
            listOf("upgrade-insecure-requests", "script-src 'none'", "object-src 'none'", "frame-src 'none'"),
            directives,
        )
        for (darkMode in listOf(false, true)) {
            val out = articleReaderDocument("<article><p>Hello</p></article>", darkMode)
            assertTrue(out.startsWith(ARTICLE_READER_POLICY_META))
            assertTrue(out.contains("<article><p>Hello</p></article>"))
            assertEquals(ARTICLE_READER_POLICY_META + readerModeHtml("<article><p>Hello</p></article>", darkMode), out)
        }
    }

    @Test
    fun `nothing an article carries comes before the reader document's policy`() {
        // Only a policy in the head applies, and the head ends at the first
        // content. Each of these moves the http upgrade's meta when it is
        // placed by upgradeInsecureRequests; none may move this one.
        val openers =
            listOf(
                "<head>",
                "<html>",
                "<!doctype html>",
                "<header>",
                "</head><body>",
                "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src * 'unsafe-inline'\">",
            )
        for (opener in openers) {
            val article = "$opener<img src=x onerror=\"document.title='js-ran'\">"
            val out = articleReaderDocument(article, darkMode = false)
            assertEquals(0, out.indexOf(ARTICLE_READER_POLICY_META), opener)
            assertTrue(out.indexOf(opener) > ARTICLE_READER_POLICY_META.length, opener)
        }
    }
}
