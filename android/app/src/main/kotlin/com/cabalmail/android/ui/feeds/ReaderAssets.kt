package com.cabalmail.android.ui.feeds

import android.content.Context
import com.cabalmail.kit.models.articleReaderDocument

/**
 * The vendored Readability.js the article view injects for its reader
 * mode (rss plan, phase 6d; the Apple kit's `ReaderAssets`). Neither
 * `WKWebView` nor Android's WebView exposes the browser's own reader, so
 * the app extracts the article itself. Materialized into
 * `assets/reader/` by `android/scripts/sync-vendored.sh` from
 * `react/admin/node_modules/@mozilla/readability` (the pin lives in
 * `react/admin/package.json`); a build that skipped the script simply
 * offers no reader toggle.
 */
object ReaderAssets {
    private const val PATH = "reader/Readability.js"

    @Volatile
    private var cached: String? = null

    @Volatile
    private var missing = false

    /** Readability.js source, or null when the asset is absent from this build. */
    fun readabilityScript(context: Context): String? {
        cached?.let { return it }
        if (missing) return null
        val text =
            runCatching {
                context.assets
                    .open(PATH)
                    .bufferedReader()
                    .use { it.readText() }
            }.getOrNull()
        if (text == null) missing = true else cached = text
        return text
    }

    /**
     * The program run after the script: Readability over a clone of the
     * live document, returning the extraction as JSON text (or null). The
     * video pattern matches nothing, so Readability drops every iframe,
     * embed and object, video players included: reader mode runs no
     * third-party code, and the players stay on the publisher's page.
     */
    const val EXTRACTION_PROGRAM = """
        (function () {
          try {
            var article = new Readability(document.cloneNode(true), { allowedVideoRegex: /(?!)/ }).parse();
            if (!article) { return null; }
            return JSON.stringify({ title: article.title || "", byline: article.byline || "",
                                    content: article.content || "" });
          } catch (e) { return null; }
        })();
    """
}

/** What Readability returned for a page. */
data class ExtractedArticle(
    val title: String,
    val byline: String,
    val content: String,
)

/** The reader document built from an extraction, the Apple `ArticleReaderDocument`. */
object ArticleReaderDocument {
    /**
     * The whole document the article view loads for reader mode: the
     * article in the reader stylesheet, behind the policy that refuses
     * script, plugins and frames (`articleReaderDocument`).
     */
    fun document(
        article: ExtractedArticle,
        sourceHost: String,
        darkMode: Boolean,
    ): String = articleReaderDocument(html(article, sourceHost), darkMode)

    /** The article's markup under its title and byline; [document] wraps it. */
    fun html(
        article: ExtractedArticle,
        sourceHost: String,
    ): String {
        val title = escape(article.title)
        val meta = listOf(escape(article.byline), escape(sourceHost)).filter { it.isNotEmpty() }.joinToString(" · ")
        val byline = if (meta.isEmpty()) "" else "<p class=\"cabal-byline\"><small>$meta</small></p>"
        return "<article>\n<h1>$title</h1>\n$byline\n${article.content}\n</article>"
    }

    fun escape(text: String): String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}
