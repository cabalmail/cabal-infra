package com.cabalmail.android.ui.feeds

import android.annotation.SuppressLint
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.cabalmail.android.R

/**
 * The publisher's page (D6 = C: no server-side extraction). JavaScript on,
 * since live pages need it; cookies and storage in a profile of the
 * subscription's own (D11), so a login on one feed's site never reaches
 * another feed's, even at the same publisher — the `androidx.webkit`
 * multi-profile API where the installed WebView has it, the default
 * profile where it does not. WebKit's error page is replaced by a notice
 * with Retry; system back walks the page history before leaving the
 * article. The Readability reader toggle arrives with 6d.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun ArticleWebView(
    url: String,
    profileName: String,
    online: Boolean,
    onLeave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var failure by remember(url) { mutableStateOf<String?>(null) }
    var attempt by remember(url) { mutableIntStateOf(0) }
    var canGoBack by remember { mutableStateOf(false) }
    var webView by remember { mutableStateOf<WebView?>(null) }

    BackHandler(enabled = canGoBack) { webView?.goBack() }

    Box(modifier = modifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                WebView(context).apply {
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
                                val scheme = request?.url?.scheme?.lowercase()
                                // Stay inside the web view for web links; hand anything else to the system.
                                return scheme != "http" && scheme != "https"
                            }

                            override fun onPageFinished(
                                view: WebView?,
                                finishedUrl: String?,
                            ) {
                                canGoBack = view?.canGoBack() == true
                                failure = null
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
                    view.loadUrl(url)
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
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
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
                    androidx.compose.material3.TextButton(onClick = onLeave) {
                        Text(stringResource(R.string.feed_article_back))
                    }
                }
            }
        }
    }
}
