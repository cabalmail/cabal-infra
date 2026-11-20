package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.ARTICLE_READER_POLICY_META
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The article view's reader state machine against a recorded web view: the
 * reader document never loads with the web view's JavaScript on, and no
 * other page loads with it off. What a real WebView then does with a
 * document loaded that way is checked in the running app, not here.
 */
class ArticleReaderTest {
    /** A web view that writes down what it is asked, in order. */
    private class RecordingPage : ArticlePage {
        /** A new web view starts with JavaScript off. */
        var javaScript = false
        val calls = mutableListOf<String>()
        val documents = mutableListOf<String>()
        val programs = mutableListOf<String>()
        val scriptsOnAtEvaluation = mutableListOf<Boolean>()
        var screenUrl = ""
        private var answer: ((String?) -> Unit)? = null

        override fun setJavaScriptEnabled(enabled: Boolean) {
            javaScript = enabled
            calls += "js:$enabled"
        }

        override fun loadUrl(url: String) {
            calls += "url:$url"
            screenUrl = url
        }

        override fun loadDocument(
            pageUrl: String,
            html: String,
        ) {
            calls += "doc:$pageUrl"
            documents += html
            screenUrl = pageUrl
        }

        override fun goBack() {
            calls += "back"
        }

        override fun evaluate(
            program: String,
            onResult: (String?) -> Unit,
        ) {
            calls += "eval"
            programs += program
            scriptsOnAtEvaluation += javaScript
            answer = onResult
        }

        /** Hands the waiting extraction its result; false when none is waiting. */
        fun answer(result: String?): Boolean {
            val waiting = answer ?: return false
            answer = null
            waiting(result)
            return true
        }
    }

    private var leftReader = 0

    private fun reader(script: String? = "READABILITY") =
        ArticleReader(
            pageUrl = ARTICLE,
            script = script,
            readerDocument = { article, pageUrl ->
                ArticleReaderDocument.document(article, pageUrl.removePrefix("https://").substringBefore('/'), false)
            },
            onLeftReader = { leftReader += 1 },
        )

    /** Opens the article with the reader asked for and lets the extraction answer. */
    private fun ArticleReader.openInReader(page: RecordingPage) {
        open(page, ARTICLE, wantsReader = true)
        pageFinished(page, ARTICLE)
        assertTrue(page.answer(EXTRACTION))
        pageFinished(page, ARTICLE)
    }

    @Test
    fun `only the reader document loads with scripts off`() {
        assertEquals(
            mapOf(
                ArticleLoad.LIVE_PAGE to true,
                ArticleLoad.READER_DOCUMENT to false,
                ArticleLoad.TOGGLE_BACK to true,
                ArticleLoad.LINK_OUT_OF_READER to true,
                ArticleLoad.HISTORY_BACK to true,
                ArticleLoad.PAGE_NAVIGATION to true,
            ),
            ArticleLoad.entries.associateWith { ArticleScriptPolicy.allowsJavaScript(it) },
        )
    }

    @Test
    fun `the article opens with scripts on, and the extraction runs in the live page`() {
        val page = RecordingPage()
        val reader = reader()
        reader.open(page, ARTICLE, wantsReader = true)
        assertEquals(listOf("js:true", "url:$ARTICLE"), page.calls)
        reader.pageFinished(page, ARTICLE)
        assertEquals(listOf("js:true", "url:$ARTICLE", "eval"), page.calls)
        assertEquals(listOf(true), page.scriptsOnAtEvaluation)
        assertEquals("READABILITY\n" + ReaderAssets.EXTRACTION_PROGRAM, page.programs.single())
    }

    @Test
    fun `the reader document loads with scripts off, behind its policy`() {
        val page = RecordingPage()
        val reader = reader()
        reader.open(page, ARTICLE, wantsReader = true)
        reader.pageFinished(page, ARTICLE)
        assertTrue(page.answer(EXTRACTION))
        assertEquals(listOf("js:true", "url:$ARTICLE", "eval", "js:false", "doc:$ARTICLE"), page.calls)
        assertTrue(reader.showingReader)
        val document = page.documents.single()
        assertTrue(document.startsWith(ARTICLE_READER_POLICY_META), "the policy leads the document")
        // The article's handler is still in the markup; nothing here strips
        // it, so the two locks are what keep it from running.
        assertTrue(document.contains("onerror=\"document.title='js-ran'\""))
        assertTrue(document.contains("news.example"))
    }

    @Test
    fun `scripts stay off for as long as the reader is on screen`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        val shown = page.calls.toList()
        repeat(3) { reader.ask(page, wantsReader = true) }
        reader.pageFinished(page, ARTICLE)
        assertEquals(shown, page.calls)
        assertFalse(page.javaScript)
    }

    @Test
    fun `the toggle goes back to the publisher's page with scripts on, and that page stays`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        page.calls.clear()
        reader.ask(page, wantsReader = false)
        assertEquals(listOf("js:true", "url:$ARTICLE"), page.calls)
        assertFalse(reader.showingReader)
        // The page finishing must not put the reader back: the toggle's last
        // word holds, not the one the web view was built beside.
        reader.pageFinished(page, ARTICLE)
        assertEquals(listOf("js:true", "url:$ARTICLE"), page.calls)
        assertTrue(page.javaScript)
    }

    @Test
    fun `the reader asked for on an open page stays once it has loaded`() {
        val page = RecordingPage()
        val reader = reader()
        reader.open(page, ARTICLE, wantsReader = false)
        reader.pageFinished(page, ARTICLE)
        assertEquals(listOf("js:true", "url:$ARTICLE"), page.calls)
        reader.ask(page, wantsReader = true)
        assertTrue(page.answer(EXTRACTION))
        reader.pageFinished(page, ARTICLE)
        assertEquals(listOf("js:true", "url:$ARTICLE", "eval", "js:false", "doc:$ARTICLE"), page.calls)
        assertTrue(reader.showingReader)
    }

    @Test
    fun `asking for the reader again shows the kept document, scripts off, without a second extraction`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        reader.ask(page, wantsReader = false)
        reader.pageFinished(page, ARTICLE)
        page.calls.clear()
        reader.ask(page, wantsReader = true)
        assertEquals(listOf("js:false", "doc:$ARTICLE"), page.calls)
        assertEquals(page.documents[0], page.documents[1])
    }

    @Test
    fun `a link tapped in the reader loads its page with scripts on, and the page stays as served`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        page.calls.clear()
        val kept = reader.navigation(page, LINKED, "https", hasGesture = true, isForMainFrame = true)
        assertTrue(kept, "the view loads the link itself, after turning scripts on")
        assertEquals(listOf("js:true", "url:$LINKED"), page.calls)
        assertEquals(1, leftReader)
        assertFalse(reader.showingReader)
        assertEquals(LINKED, reader.pageUrl)
        // Still asked for the reader, but this page is the one a link led to (#2060).
        reader.pageFinished(page, LINKED)
        reader.ask(page, wantsReader = true)
        assertEquals(listOf("js:true", "url:$LINKED"), page.calls)
        // Asking again is what extracts it.
        reader.ask(page, wantsReader = false)
        reader.ask(page, wantsReader = true)
        assertEquals(listOf("js:true", "url:$LINKED", "eval"), page.calls)
        assertEquals(listOf(true, true), page.scriptsOnAtEvaluation)
    }

    @Test
    fun `back turns scripts on before the web view goes back`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        page.calls.clear()
        reader.back(page)
        assertEquals(listOf("js:true", "back"), page.calls)
    }

    @Test
    fun `only web pages load in the article view`() {
        val page = RecordingPage()
        val reader = reader()
        reader.openInReader(page)
        page.calls.clear()
        for (scheme in listOf("intent", "javascript", "file", "content", "data", "mailto", null)) {
            assertTrue(
                reader.navigation(page, "$scheme:x", scheme, hasGesture = true, isForMainFrame = true),
                "a $scheme link must not load",
            )
        }
        assertEquals(emptyList<String>(), page.calls)
        assertTrue(reader.showingReader)
        assertFalse(page.javaScript)
    }

    @Test
    fun `a navigation the page starts goes ahead with scripts on, and a frame's changes nothing`() {
        val page = RecordingPage()
        val reader = reader()
        reader.open(page, ARTICLE, wantsReader = false)
        reader.pageFinished(page, ARTICLE)
        page.calls.clear()
        assertFalse(reader.navigation(page, LINKED, "HTTPS", hasGesture = false, isForMainFrame = true))
        assertEquals(listOf("js:true"), page.calls)
        assertFalse(reader.navigation(page, LINKED, "https", hasGesture = true, isForMainFrame = true))
        page.calls.clear()
        assertFalse(reader.navigation(page, LINKED, "https", hasGesture = false, isForMainFrame = false))
        assertEquals(emptyList<String>(), page.calls)
    }

    @Test
    fun `a page with no article stays live, with its scripts on`() {
        val page = RecordingPage()
        val reader = reader()
        reader.open(page, ARTICLE, wantsReader = true)
        reader.pageFinished(page, ARTICLE)
        assertTrue(page.answer("null"))
        assertEquals(listOf("js:true", "url:$ARTICLE", "eval"), page.calls)
        assertFalse(reader.showingReader)
        assertTrue(page.javaScript)
    }

    @Test
    fun `a build without Readability never shows the reader`() {
        val page = RecordingPage()
        val reader = reader(script = null)
        reader.open(page, ARTICLE, wantsReader = true)
        reader.pageFinished(page, ARTICLE)
        reader.ask(page, wantsReader = true)
        assertEquals(listOf("js:true", "url:$ARTICLE"), page.calls)
    }

    @Test
    fun `a fresh web view after a lost renderer opens the article with scripts on`() {
        val reader = reader()
        reader.openInReader(RecordingPage())
        reader.rendererGone()
        val fresh = RecordingPage()
        reader.open(fresh, ARTICLE, wantsReader = true)
        assertEquals(listOf("js:true", "url:$ARTICLE"), fresh.calls)
        assertFalse(reader.showingReader)
        reader.pageFinished(fresh, ARTICLE)
        // The document is kept from before; it loads into the new view scripts off.
        assertEquals(listOf("js:true", "url:$ARTICLE", "js:false", "doc:$ARTICLE"), fresh.calls)
    }

    /**
     * Every order of events up to [DEPTH] long after the article opens, with
     * the reader asked for and not, and not only the paths above: whatever
     * the user, the page and the web view do, a reader document is
     * loaded straight after scripts are turned off, any other load straight
     * after they are turned on, nothing turns them on without loading
     * something (or letting the page's own navigation through), and the
     * extraction never runs in a page whose scripts are off.
     */
    @Test
    fun `no order of events loads a reader document with scripts on or a page with them off`() {
        val events = Event.entries
        var sequences = 0
        var readerLoads = 0
        val sequence = IntArray(DEPTH)

        fun run(
            length: Int,
            opensInReader: Boolean,
        ) {
            var page = RecordingPage()
            val pages = mutableListOf(page)
            val reader = reader()
            var wants = opensInReader
            var linked = 0
            // Positions in a page's calls where a navigation was left to the web view.
            val letThrough = mutableSetOf<Pair<RecordingPage, Int>>()
            // A web view reports nothing before its first load.
            reader.open(page, ARTICLE, wants)
            for (step in 0 until length) {
                when (events[sequence[step]]) {
                    Event.OPEN -> reader.open(page, ARTICLE, wants)
                    Event.ASK_READER -> {
                        wants = true
                        reader.ask(page, wants)
                    }
                    Event.ASK_ORIGINAL -> {
                        wants = false
                        reader.ask(page, wants)
                    }
                    Event.FINISH -> reader.pageFinished(page, page.screenUrl)
                    Event.ARTICLE_FOUND -> page.answer(EXTRACTION)
                    Event.NO_ARTICLE -> page.answer("null")
                    Event.LINK -> {
                        linked += 1
                        val at = page.calls.size
                        val kept =
                            reader.navigation(page, "$LINKED$linked", "https", hasGesture = true, isForMainFrame = true)
                        if (!kept) letThrough += page to at
                    }
                    Event.PAGE_NAVIGATES -> {
                        val at = page.calls.size
                        val kept = reader.navigation(page, LINKED, "https", hasGesture = false, isForMainFrame = true)
                        if (!kept) letThrough += page to at
                    }
                    Event.FRAME_NAVIGATES ->
                        reader.navigation(page, LINKED, "https", hasGesture = false, isForMainFrame = false)
                    Event.BACK -> reader.back(page)
                    Event.RENDERER_GONE -> {
                        reader.rendererGone()
                        page = RecordingPage()
                        pages += page
                        reader.open(page, ARTICLE, wants)
                    }
                }
            }
            for (recorded in pages) {
                val calls = recorded.calls
                val trace = { "reader=$opensInReader ${sequence.take(length).map { events[it] }}: $calls" }
                calls.forEachIndexed { index, call ->
                    val before = calls.getOrNull(index - 1)
                    val after = calls.getOrNull(index + 1)
                    when {
                        call.startsWith("doc:") -> {
                            readerLoads += 1
                            assertEquals("js:false", before) { trace() }
                        }
                        call.startsWith("url:") || call == "back" -> assertEquals("js:true", before) { trace() }
                        call == "js:false" -> assertTrue(after?.startsWith("doc:") == true) { trace() }
                        call == "js:true" ->
                            assertTrue(
                                after?.startsWith("url:") == true ||
                                    after == "back" ||
                                    (recorded to index) in letThrough,
                            ) { trace() }
                    }
                }
                assertTrue(recorded.scriptsOnAtEvaluation.all { it }) { trace() }
            }
            sequences += 1
        }

        fun walk(depth: Int) {
            run(depth, opensInReader = false)
            run(depth, opensInReader = true)
            if (depth == DEPTH) return
            for (event in events.indices) {
                sequence[depth] = event
                walk(depth + 1)
            }
        }
        walk(0)
        // The walk is only worth its name if it reached the reader many times.
        assertTrue(sequences > 100_000, "walked only $sequences sequences")
        assertTrue(readerLoads > 1_000, "only $readerLoads reader loads in $sequences sequences")
    }

    private enum class Event {
        OPEN,
        ASK_READER,
        ASK_ORIGINAL,
        FINISH,
        ARTICLE_FOUND,
        NO_ARTICLE,
        LINK,
        PAGE_NAVIGATES,
        FRAME_NAVIGATES,
        BACK,
        RENDERER_GONE,
    }

    private companion object {
        const val DEPTH = 5
        const val ARTICLE = "https://news.example/article"
        const val LINKED = "https://other.example/page"

        /** What `evaluateJavascript` hands back: the extraction's JSON, quoted. */
        const val EXTRACTION =
            "\"{\\\"title\\\":\\\"T\\\",\\\"byline\\\":\\\"\\\",\\\"content\\\":" +
                "\\\"<p>body</p><img src=x onerror=\\\\\\\"document.title='js-ran'\\\\\\\">\\\"}\""
    }
}
