package com.cabalmail.android.ui.feeds

/** The loads the article view starts, and the one kind it lets a page start. */
internal enum class ArticleLoad {
    /** The publisher's page: the article's first load, and Retry's. */
    LIVE_PAGE,

    /** The reader rendering of the page on screen. */
    READER_DOCUMENT,

    /** The publisher's page again, when the toggle leaves the reader. */
    TOGGLE_BACK,

    /** The page a link tapped in the reader leads to. */
    LINK_OUT_OF_READER,

    /** One step back through the view's history. */
    HISTORY_BACK,

    /** A navigation the page on screen started itself and the view lets through. */
    PAGE_NAVIGATION,
}

/** The article view's script rule, apart from the web view so it can be tested without one. */
internal object ArticleScriptPolicy {
    /**
     * Page JavaScript is off for the reader document's load and on for every
     * other: the publisher's page needs its scripts, and so does the page a
     * link in the reader leads to, or the page the toggle goes back to. The
     * reader document holds the publisher's markup, inline event handlers
     * included, and runs none of it. The Apple
     * `ArticleNavigationPolicy.allowsJavaScript`.
     *
     * Android's switch belongs to the web view, not to one load, so it is
     * set before each load starts, and it stays off from the reader
     * document's load until the view next loads something. Back turns it on,
     * for the publisher's page it usually returns to. A reader document Back
     * brings back instead loads with scripts on, and what holds it is the
     * policy it carries (`ARTICLE_READER_POLICY_META`): without that policy
     * its handlers run, as a build with the policy taken out showed.
     */
    fun allowsJavaScript(load: ArticleLoad): Boolean = load != ArticleLoad.READER_DOCUMENT
}

/** What [ArticleReader] asks of the web view: `WebView`'s own calls, one for one. */
internal interface ArticlePage {
    fun setJavaScriptEnabled(enabled: Boolean)

    fun loadUrl(url: String)

    /** `loadDataWithBaseURL`: [html] as the page at [pageUrl]. */
    fun loadDocument(
        pageUrl: String,
        html: String,
    )

    fun goBack()

    /** `evaluateJavascript`: runs [program] in the page on screen. */
    fun evaluate(
        program: String,
        onResult: (String?) -> Unit,
    )
}

/**
 * The article view's page and reader state for one article, apart from the
 * composable so it runs in a unit test against a recorded [ArticlePage].
 * The toggle says what is asked for; [showingReader] is what is on screen.
 * When they differ and the publisher's page has finished loading, the page
 * is extracted and its reader document shown, or the page loaded again.
 *
 * Every load starts in [start], which sets the web view's JavaScript for
 * that load first ([ArticleScriptPolicy]). Nothing else here, and nothing
 * in the composable, loads a page or touches the setting.
 */
internal class ArticleReader(
    pageUrl: String,
    /** Readability's source, or null when this build has no reader. */
    private val script: String?,
    /** Builds the reader document for an extraction of the page at the given URL. */
    private val readerDocument: (article: ExtractedArticle, pageUrl: String) -> String,
    /** Reports that a link tapped in the reader is opening its page (#2060). */
    private val onLeftReader: () -> Unit,
) {
    /** The publisher's page this view is on: the article's, or the last one a link led to. */
    var pageUrl: String = pageUrl
        private set

    var showingReader = false
        private set

    private var wantsReader = false
    private var pageLoaded = false
    private var extracting = false

    /** The reader document of [pageUrl], kept so the toggle does not extract twice. */
    private var document: String? = null

    /**
     * The page on screen was reached by a link out of the reader, so it stays
     * as the publisher served it however the toggle reads (#2060). Holds on
     * its own: the view model's own per-page state arrives a recomposition
     * later, after this page may already have finished loading.
     */
    private var leftThroughLink = false

    /** What the toggle last asked for, so a move of it can be told from a recomposition. */
    private var askedForReader: Boolean? = null

    /** The article's first load, a fresh web view's after a lost renderer, and Retry's. */
    fun open(
        page: ArticlePage,
        url: String,
        wantsReader: Boolean,
    ) {
        this.wantsReader = wantsReader
        showingReader = false
        pageLoaded = false
        leftThroughLink = false
        start(page, ArticleLoad.LIVE_PAGE) { loadUrl(url) }
    }

    /** The toggle's state, on every recomposition. */
    fun ask(
        page: ArticlePage,
        wantsReader: Boolean,
    ) {
        this.wantsReader = wantsReader
        reconcile(page)
    }

    /** `onPageFinished`, with the URL the web view reports for the page on screen. */
    fun pageFinished(
        page: ArticlePage,
        currentUrl: String,
    ) {
        pageLoaded = true
        // A new live page invalidates the extraction of the previous one.
        if (!showingReader && currentUrl.startsWith("http") && currentUrl != pageUrl) {
            pageUrl = currentUrl
            document = null
        }
        reconcile(page)
    }

    /**
     * `shouldOverrideUrlLoading`: true keeps the navigation from the web
     * view. Only web pages load here. A link tapped in the reader leaves it
     * for the live page, loaded by the view so its scripts are on first, and
     * that page stays as served rather than being extracted again when it
     * finishes loading (#2060).
     */
    fun navigation(
        page: ArticlePage,
        url: String,
        scheme: String?,
        hasGesture: Boolean,
        isForMainFrame: Boolean,
    ): Boolean {
        if (scheme?.lowercase() !in WEB_SCHEMES) return true
        if (showingReader && hasGesture) {
            showingReader = false
            document = null
            pageUrl = url
            pageLoaded = false
            leftThroughLink = true
            onLeftReader()
            start(page, ArticleLoad.LINK_OUT_OF_READER) { loadUrl(url) }
            return true
        }
        if (isForMainFrame) start(page, ArticleLoad.PAGE_NAVIGATION)
        return false
    }

    /** System back, while the web view has history to walk. */
    fun back(page: ArticlePage) {
        start(page, ArticleLoad.HISTORY_BACK) { goBack() }
    }

    /** The renderer is gone, and with it any extraction that was running. */
    fun rendererGone() {
        extracting = false
    }

    private fun reconcile(page: ArticlePage) {
        val asked = wantsReader && script != null
        // The toggle moving is the user asking again, which is what ends a
        // link-out's hold on this page (#2060).
        if (askedForReader != asked) {
            if (askedForReader != null) leftThroughLink = false
            askedForReader = asked
        }
        val wants = FeedDetailPolicy.showsReader(asked, leftThroughLink)
        if (wants == showingReader || !pageLoaded || extracting) return
        if (wants) {
            val cached = document
            if (cached != null) show(page, cached) else extract(page)
        } else {
            showingReader = false
            pageLoaded = false
            leftThroughLink = false
            start(page, ArticleLoad.TOGGLE_BACK) { loadUrl(pageUrl) }
        }
    }

    private fun extract(page: ArticlePage) {
        val readability = script ?: return
        extracting = true
        page.evaluate(readability + "\n" + ReaderAssets.EXTRACTION_PROGRAM) { result ->
            extracting = false
            // No article: the live page stays, and the toggle still reads
            // "reader".
            val article = decodeExtraction(result) ?: return@evaluate
            val built = readerDocument(article, pageUrl)
            document = built
            show(page, built)
        }
    }

    private fun show(
        page: ArticlePage,
        html: String,
    ) {
        showingReader = true
        leftThroughLink = false
        pageLoaded = false
        start(page, ArticleLoad.READER_DOCUMENT) { loadDocument(pageUrl, html) }
    }

    /** Sets the web view's JavaScript for [load], then starts it. */
    private fun start(
        page: ArticlePage,
        load: ArticleLoad,
        begin: ArticlePage.() -> Unit = {},
    ) {
        page.setJavaScriptEnabled(ArticleScriptPolicy.allowsJavaScript(load))
        page.begin()
    }

    private companion object {
        /** The schemes of a page a publisher serves. */
        val WEB_SCHEMES = setOf("http", "https")
    }
}
