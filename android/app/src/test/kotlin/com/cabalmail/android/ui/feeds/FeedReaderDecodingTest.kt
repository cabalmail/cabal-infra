package com.cabalmail.android.ui.feeds

import kotlinx.coroutines.Dispatchers
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
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
}
