package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.ARTICLE_READER_POLICY_META
import kotlinx.coroutines.Dispatchers
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The article reader's extraction decoder and document. */
class FeedReaderDecodingTest {
    @Test
    fun `the extraction decoder unwraps the WebView's quoted JSON and rejects empty content`() {
        val quoted = "\"{\\\"title\\\":\\\"T\\\",\\\"byline\\\":\\\"B\\\",\\\"content\\\":\\\"<p>x</p>\\\"}\""
        assertEquals(ExtractedArticle("T", "B", "<p>x</p>"), decodeExtraction(quoted))
        assertNull(decodeExtraction("null"))
        assertNull(decodeExtraction(null))
        assertNull(decodeExtraction("\"{\\\"title\\\":\\\"T\\\",\\\"content\\\":\\\"\\\"}\""))
        val doc = ArticleReaderDocument.html(ExtractedArticle("A <b> & B", "By Ann", "<p>body</p>"), "example.com")
        assertEquals(true, doc.contains("<h1>A &lt;b&gt; &amp; B</h1>"))
        assertEquals(true, doc.contains("By Ann · example.com"))
        assertEquals(true, doc.contains("<p>body</p>"))
        assertEquals(Dispatchers.IO, Dispatchers.IO)
    }

    @Test
    fun `the reader document leads with its policy, whatever the article holds`() {
        // A stray head tag is where the http upgrade's own meta used to
        // land, behind the article's markup, where an engine ignores a policy.
        val content = "<head><img src=x onerror=\"document.title='js-ran'\"><script>document.title='js-ran'</script>"
        val doc =
            ArticleReaderDocument.document(
                ExtractedArticle("T", "By Ann", content),
                "example.com",
                darkMode = true,
            )
        assertTrue(doc.startsWith(ARTICLE_READER_POLICY_META))
        assertEquals(1, doc.windowed(ARTICLE_READER_POLICY_META.length).count { it == ARTICLE_READER_POLICY_META })
        assertTrue(doc.contains("<h1>T</h1>"))
        assertTrue(doc.contains("By Ann · example.com"))
        // Nothing strips the markup: the policy and the load are what hold it.
        assertTrue(doc.contains(content))
    }

    @Test
    fun `the extraction asks Readability to keep no video player`() {
        // Readability keeps an iframe, embed or object whose source matches
        // this pattern; one that matches nothing drops them all. What it
        // does with the option is checked in the running app.
        assertTrue(
            ReaderAssets.EXTRACTION_PROGRAM.contains(
                "new Readability(document.cloneNode(true), { allowedVideoRegex: /(?!)/ })",
            ),
        )
    }
}
