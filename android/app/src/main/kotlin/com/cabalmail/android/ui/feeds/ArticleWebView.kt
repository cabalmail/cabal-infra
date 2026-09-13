package com.cabalmail.android.ui.feeds

import android.annotation.SuppressLint
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import com.cabalmail.kit.models.readerModeHtml
import com.cabalmail.kit.models.upgradeInsecureRequests
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The publisher's page (D6 = C: no server-side extraction). JavaScript on,
 * since live pages need it; cookies and storage in a profile of the
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
 * reader mode for the live destination, as Safari's Reader does.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun ArticleWebView(
    url: String,
    profileName: String,
    online: Boolean,
    onLeave: () -> Unit,
    modifier: Modifier = Modifier,
    /** The reader toggle's state; ignored when the script is not in this build. */
    wantsReader: Boolean = false,
) {
    val context = LocalContext.current
    val darkMode = isSystemInDarkTheme()
    val script = remember { ReaderAssets.readabilityScript(context) }
    var failure by remember(url) { mutableStateOf<String?>(null) }
    var attempt by remember(url) { mutableIntStateOf(0) }
    var canGoBack by remember { mutableStateOf(false) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val reader = remember(url) { ReaderState(url) }

    BackHandler(enabled = canGoBack) { webView?.goBack() }

    fun reconcile(view: WebView) {
        val wants = wantsReader && script != null
        if (wants == reader.showingReader || !reader.pageLoaded || reader.extracting) return
        if (wants) {
            val cached = reader.readerDocument
            if (cached != null) {
                reader.show(view, cached)
            } else {
                reader.extracting = true
                view.evaluateJavascript(script + "\n" + ReaderAssets.EXTRACTION_PROGRAM) { result ->
                    reader.extracting = false
                    val article = decodeExtraction(result)
                    if (article == null) return@evaluateJavascript
                    val body =
                        ArticleReaderDocument.html(
                            article,
                            reader.pageUrl
                                .toUri()
                                .host
                                .orEmpty(),
                        )
                    val document = upgradeInsecureRequests(readerModeHtml(body, darkMode))
                    reader.readerDocument = document
                    reader.show(view, document)
                }
            }
        } else {
            reader.showingReader = false
            reader.pageLoaded = false
            view.loadUrl(reader.pageUrl)
        }
    }

    Box(modifier = modifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    // The profile must be chosen before the first load.
                    if (profileName.isNotEmpty() && WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                        runCatching { WebViewCompat.setProfile(this, profileName) }
                    }
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    webViewClient =
                        object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(
                                view: WebView?,
                                request: WebResourceRequest?,
                            ): Boolean {
                                val target = request?.url ?: return false
                                val scheme = target.scheme?.lowercase()
                                if (scheme != "http" && scheme != "https") return true
                                // A link followed from the reader leaves reader mode for the live page.
                                if (reader.showingReader && request.hasGesture()) {
                                    reader.showingReader = false
                                    reader.readerDocument = null
                                    reader.pageUrl = target.toString()
                                    reader.pageLoaded = false
                                    view?.loadUrl(reader.pageUrl)
                                    return true
                                }
                                return false
                            }

                            override fun onPageFinished(
                                view: WebView?,
                                finishedUrl: String?,
                            ) {
                                canGoBack = view?.canGoBack() == true
                                failure = null
                                reader.pageLoaded = true
                                // A new live page invalidates the extraction of the previous one.
                                val current = view?.url.orEmpty()
                                if (!reader.showingReader && current.startsWith("http") && current != reader.pageUrl) {
                                    reader.pageUrl = current
                                    reader.readerDocument = null
                                }
                                view?.let { reconcile(it) }
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
                        }
                    webView = this
                }
            },
            update = { view ->
                val loadKey = url to attempt
                if (view.tag != loadKey) {
                    view.tag = loadKey
                    reader.showingReader = false
                    reader.pageLoaded = false
                    view.loadUrl(url)
                } else {
                    reconcile(view)
                }
            },
            onRelease = { view ->
                webView = null
                view.destroy()
            },
        )
        val notice = failure
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

/** The reader mode's bookkeeping for one article view. */
private class ReaderState(
    var pageUrl: String,
) {
    var showingReader = false
    var pageLoaded = false
    var extracting = false
    var readerDocument: String? = null

    fun show(
        view: WebView,
        document: String,
    ) {
        showingReader = true
        pageLoaded = false
        view.loadDataWithBaseURL(pageUrl, document, "text/html", "utf-8", pageUrl)
    }
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
