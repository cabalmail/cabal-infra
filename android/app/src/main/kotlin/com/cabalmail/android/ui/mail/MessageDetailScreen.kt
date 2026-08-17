package com.cabalmail.android.ui.mail

import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.cabalmail.android.R
import com.cabalmail.kit.models.mailboxDisplayName
import com.cabalmail.kit.models.sentInstant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageDetailScreen(
    state: MessageDetailUiState,
    isTrashFolder: Boolean,
    onToggleSeen: () -> Unit,
    onToggleFlag: () -> Unit,
    onDispose: () -> Unit,
    onAllowRemoteContent: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(state.departed) {
        if (state.departed) {
            onBack()
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onToggleSeen, enabled = !state.busy) {
                        Icon(Icons.Default.Email, contentDescription = stringResource(R.string.toggle_read))
                    }
                    IconButton(onClick = onToggleFlag, enabled = !state.busy) {
                        Icon(
                            Icons.Default.Star,
                            contentDescription = stringResource(R.string.flagged),
                            tint =
                                if (state.envelope?.isFlagged == true) {
                                    MaterialTheme.colorScheme.tertiary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                        )
                    }
                    IconButton(onClick = onDispose, enabled = !state.busy) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription =
                                stringResource(
                                    if (isTrashFolder) R.string.purge else R.string.archive,
                                ),
                            tint =
                                if (isTrashFolder) {
                                    MaterialTheme.colorScheme.error
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            state.envelope?.let { envelope ->
                Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    Text(
                        text = envelope.subject.ifEmpty { stringResource(R.string.no_subject) },
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = envelope.from.joinToString { mailboxDisplayName(it) },
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        text =
                            envelope.sentInstant()?.let {
                                DateTimeFormatter
                                    .ofLocalizedDateTime(FormatStyle.MEDIUM)
                                    .withZone(ZoneId.systemDefault())
                                    .format(it)
                            } ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
            }

            state.error?.let { message ->
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
            }
            if (state.busy && state.content == null) {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
            }

            val content = state.content
            if (content != null) {
                if (content.bodyHtml.isNotBlank()) {
                    if (!state.loadRemoteContent) {
                        TextButton(
                            onClick = onAllowRemoteContent,
                            modifier = Modifier.padding(horizontal = 8.dp),
                        ) {
                            Text(stringResource(R.string.load_remote_content))
                        }
                    }
                    HtmlBody(
                        html = content.bodyHtml,
                        allowRemoteContent = state.loadRemoteContent,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    SelectionContainer(
                        modifier =
                            Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(16.dp),
                    ) {
                        Text(
                            text = content.bodyPlain,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Hardened HTML rendering, mirroring the plan's WKWebView-equivalent
 * posture: no JavaScript, remote loads blocked until the per-message
 * opt-in, all navigation swallowed.
 */
@Composable
private fun HtmlBody(
    html: String,
    allowRemoteContent: Boolean,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = false
                settings.blockNetworkLoads = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webViewClient =
                    object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean = true
                    }
            }
        },
        update = { webView ->
            webView.settings.blockNetworkLoads = !allowRemoteContent
            webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
        },
    )
}
