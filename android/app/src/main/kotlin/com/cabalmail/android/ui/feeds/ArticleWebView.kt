package com.cabalmail.android.ui.feeds

import android.annotation.SuppressLint
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.net.toUri
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.RendererRecovery
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The publisher's page (D6 = C: no server-side extraction). JavaScript on
 * for the publisher's page, since live pages need it, and off for the
 * reader rendering; cookies and storage in a profile of the
 * subscription's own (D11), so a login on one feed's site never reaches
 * another feed's — the `androidx.webkit` multi-profile API where the
 * installed WebView has it, the default profile where it does not.
 * WebKit's error page is replaced by a notice with Retry; system back
 * walks the page history before leaving the article.
 *
 * Reader mode, the Apple `ArticleWebView`'s: when [wantsReader] and the
 * vendored Readability.js is in this build, the live page is cloned and
 * extracted once it has loaded, and the result shown as a reader document
 * restyled with the mail reader's stylesheet; following a link leaves
 * reader mode for the live destination, as Safari's Reader does. The
 * reader document runs no script from the article: it loads with the web
 * view's JavaScript off, and it carries a policy that refuses script,
 * plugins and frames ([ArticleReader], `articleReaderDocument`).
 *
 * A lost renderer is handled by [RendererRecovery]: a fresh WebView
 * reloads the article, or the notice offers Retry when it keeps crashing.
 */
@Composable
fun ArticleWebView(
    url: String,
    profileName: String,
    online: Boolean,
    onLeave: () -> Unit,
    modifier: Modifier = Modifier,
    /** The reader toggle's state; ignored when the script is not in this build. */
    wantsReader: Boolean = false,
    /**
     * Reports that a link tapped in the reader has opened its page, so the
     * view model can leave the reader for that page without touching the
     * feed's saved styling (#2060).
     */
    onLeftReader: () -> Unit = {},
) {
    val context = LocalContext.current
    val darkMode by rememberUpdatedState(isSystemInDarkTheme())
    val currentOnLeftReader by rememberUpdatedState(onLeftReader)
    val script = remember { ReaderAssets.readabilityScript(context) }
    var failure by remember(url) { mutableStateOf<String?>(null) }
    var attempt by remember(url) { mutableIntStateOf(0) }
    var canGoBack by remember { mutableStateOf(false) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val reader =
        remember(url) {
            ArticleReader(
                pageUrl = url,
                script = script,
                readerDocument = { article, pageUrl ->
                    ArticleReaderDocument.document(article, pageUrl.toUri().host.orEmpty(), darkMode)
                },
                onLeftReader = { currentOnLeftReader() },
            )
        }
    // The web view outlives a change of article, so its client reads these
    // through state rather than holding the ones it was built beside.
    val currentReader by rememberUpdatedState(reader)
    val recovery = remember(url) { RendererRecovery() }
    val currentRecovery by rememberUpdatedState(recovery)

    BackHandler(enabled = canGoBack) { webView?.let { reader.back(WebViewArticlePage(it)) } }

    Box(modifier = modifier) {
        if (!recovery.gaveUp) {
            key(recovery.generation) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        WebView(ctx).apply {
                            // The profile must be chosen before the first load.
                            if (profileName.isNotEmpty() &&
                                WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
                            ) {
                                runCatching { WebViewCompat.setProfile(this, profileName) }
                            }
                            // JavaScript is not set here: a web view starts with it off, and
                            // every load sets it for what that load shows (ArticleReader).
                            settings.domStorageEnabled = true
                            settings.allowFileAccess = false
                            settings.allowContentAccess = false
                            val page = WebViewArticlePage(this)
                            webViewClient =
                                object : WebViewClient() {
                                    override fun shouldOverrideUrlLoading(
                                        view: WebView?,
                                        request: WebResourceRequest?,
                                    ): Boolean {
                                        val target = request?.url ?: return false
                                        return currentReader.navigation(
                                            page = page,
                                            url = target.toString(),
                                            scheme = target.scheme,
                                            hasGesture = request.hasGesture(),
                                            isForMainFrame = request.isForMainFrame,
                                        )
                                    }

                                    override fun onPageFinished(
                                        view: WebView?,
                                        finishedUrl: String?,
                                    ) {
                                        canGoBack = view?.canGoBack() == true
                                        failure = null
                                        currentReader.pageFinished(page, view?.url.orEmpty())
                                    }

                                    override fun onReceivedError(
                                        view: WebView?,
                                        request: WebResourceRequest?,
                                        error: WebResourceError?,
                                    ) {
                                        if (request?.isForMainFrame == true) {
                                            failure = error?.description?.toString().orEmpty()
                                        }
                                    }

                                    override fun onRenderProcessGone(
                                        view: WebView?,
                                        detail: RenderProcessGoneDetail?,
                                    ): Boolean {
                                        // The fresh view starts over: no history to walk back
                                        // through, and no extraction left to answer.
                                        canGoBack = false
                                        currentReader.rendererGone()
                                        return currentRecovery.onRenderProcessGone(detail?.didCrash() == true)
                                    }
                                }
                            webView = this
                        }
                    },
                    update = { view ->
                        val page = WebViewArticlePage(view)
                        val loadKey = url to attempt
                        if (view.tag != loadKey) {
                            view.tag = loadKey
                            reader.open(page, url, wantsReader)
                        } else {
                            reader.ask(page, wantsReader)
                        }
                    },
                    onRelease = { view ->
                        // A remount can mount the fresh view before this releases the dead one.
                        if (webView === view) webView = null
                        view.destroy()
                    },
                )
            }
        }
        val notice = failure ?: stringResource(R.string.web_renderer_gone_body).takeIf { recovery.gaveUp }
        if (notice != null) {
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        stringResource(
                            if (!online) R.string.feed_article_needs_connection else R.string.feed_article_failed,
                        ),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        if (!online) stringResource(R.string.feed_article_needs_connection_body) else notice,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
                    )
                    Button(
                        onClick = {
                            failure = null
                            attempt += 1
                            recovery.retry()
                        },
                    ) { Text(stringResource(R.string.retry)) }
                    TextButton(onClick = onLeave) { Text(stringResource(R.string.feed_article_back)) }
                }
            }
        }
    }
}

/** Whether this build can offer the reader toggle in the article view. */
@Composable
fun readerScriptAvailable(): Boolean {
    val context = LocalContext.current
    return remember { ReaderAssets.readabilityScript(context) != null }
}

/**
 * The web view as [ArticleReader] drives it: each call is `WebView`'s own.
 * The one place in the app that loads a page into the article view or sets
 * its JavaScript, so that the reader's rule for them (`ArticleScriptPolicy`)
 * is the only one; `ArticleWebViewScriptScanTest` holds the source to that.
 */
private class WebViewArticlePage(
    private val view: WebView,
) : ArticlePage {
    // The value is ArticleReader's: on for the publisher's page, which needs
    // its scripts, and off for the reader rendering.
    @SuppressLint("SetJavaScriptEnabled")
    override fun setJavaScriptEnabled(enabled: Boolean) {
        view.settings.javaScriptEnabled = enabled
    }

    override fun loadUrl(url: String) = view.loadUrl(url)

    override fun loadDocument(
        pageUrl: String,
        html: String,
    ) = view.loadDataWithBaseURL(pageUrl, html, "text/html", "utf-8", pageUrl)

    override fun goBack() = view.goBack()

    override fun evaluate(
        program: String,
        onResult: (String?) -> Unit,
    ) = view.evaluateJavascript(program) { onResult(it) }
}

/** `evaluateJavascript` hands back a JSON-encoded value: a quoted string of the extraction's JSON, or `null`. */
internal fun decodeExtraction(result: String?): ExtractedArticle? {
    if (result.isNullOrEmpty() || result == "null") return null
    return runCatching {
        val inner = Json.parseToJsonElement(result).jsonPrimitive.content
        val obj = Json.parseToJsonElement(inner).jsonObject
        ExtractedArticle(
            title = obj["title"]?.jsonPrimitive?.content.orEmpty(),
            byline = obj["byline"]?.jsonPrimitive?.content.orEmpty(),
            content = obj["content"]?.jsonPrimitive?.content.orEmpty(),
        )
    }.getOrNull()?.takeIf { it.content.isNotBlank() }
}
