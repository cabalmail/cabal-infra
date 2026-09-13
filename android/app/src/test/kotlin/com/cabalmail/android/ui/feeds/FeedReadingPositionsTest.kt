package com.cabalmail.android.ui.feeds

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** The per-item reading-position cache and its `f<fraction>` anchor codec. */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedReadingPositionsTest {
    @TempDir
    lateinit var dir: File

    @Test
    fun `anchors round-trip in the Apple fallback form and the top is not stored`() {
        assertEquals("f0.420", FeedReadingAnchor.format(0.42f))
        assertEquals("f1.000", FeedReadingAnchor.format(3f))
        assertNull(FeedReadingAnchor.format(0.004f))
        assertEquals(0.42f, FeedReadingAnchor.fraction("f0.420"))
        assertNull(FeedReadingAnchor.fraction("i3/1|12"))
        assertNull(FeedReadingAnchor.fraction("f2"))
    }

    @Test
    fun `positions persist, evict the oldest beyond capacity, and clear at the top`() =
        runTest {
            val dispatcher = StandardTestDispatcher(testScheduler)
            val file = File(dir, "positions.json")
            val positions = FeedReadingPositions(file, capacity = 2, io = dispatcher)

            positions.record("f1#a", 0.25f)
            positions.record("f1#b", 0.5f)
            positions.record("f1#c", 0.75f)
            assertNull(positions.fraction("f1#a"), "oldest evicted")
            assertEquals(0.5f, positions.fraction("f1#b"))

            positions.record("f1#b", 0f)
            assertNull(positions.fraction("f1#b"), "a position at the top clears the entry")

            val reopened = FeedReadingPositions(file, io = dispatcher)
            assertEquals(0.75f, reopened.fraction("f1#c"))
            assertEquals("f0.750", reopened.anchor("f1#c"))
        }

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
