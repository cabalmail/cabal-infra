package com.cabalmail.android.ui.feeds

import android.content.Intent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.HtmlBody
import com.cabalmail.android.ui.mail.LinkMenuSheet
import com.cabalmail.android.ui.mail.LinkMenuTarget
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.kit.models.readerModeHtml
import com.cabalmail.kit.models.upgradeInsecureRequests

/**
 * One feed item: the feed's own content through the mail reader's
 * sandboxed body view (reader or original styling, remote content per the
 * feed's setting), or the publisher's article in its own web view. The
 * header always links to the article in the browser.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedItemDetailScreen(
    state: FeedItemDetailUiState,
    viewModel: FeedItemDetailViewModel,
    online: Boolean,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    showBack: Boolean = true,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var menuOpen by remember { mutableStateOf(false) }
    var linkTarget by remember { mutableStateOf<LinkMenuTarget?>(null) }
    val item = state.item
    val articleUrl = state.articleUrl
    val title = state.subscription?.displayTitle ?: stringResource(R.string.feed_title_fallback)

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    if (showBack) {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                            )
                        }
                    }
                },
                actions = {
                    if (item != null) {
                        val favoriteTint =
                            if (item.isFavorite) ColorTokens.flaggedFg() else MaterialTheme.colorScheme.onSurface
                        IconButton(onClick = { viewModel.setRead(!item.isRead) }) {
                            Icon(
                                Icons.Default.Email,
                                contentDescription =
                                    stringResource(
                                        if (item.isRead) R.string.feed_mark_as_unread else R.string.feed_mark_as_read,
                                    ),
                            )
                        }
                        IconButton(onClick = { viewModel.setFavorite(!item.isFavorite) }) {
                            Icon(
                                Icons.Default.Star,
                                contentDescription =
                                    stringResource(
                                        if (item.isFavorite) R.string.feed_remove_favorite else R.string.feed_favorite,
                                    ),
                                tint = favoriteTint,
                            )
                        }
                        IconButton(onClick = { menuOpen = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.feed_more))
                        }
                        val readerAvailable = readerScriptAvailable()
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            // In the article view the toggle needs the vendored script.
                            if (!state.showingArticle || readerAvailable) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            stringResource(
                                                if (state.readerMode) {
                                                    R.string.feed_show_original
                                                } else {
                                                    R.string.feed_show_reader
                                                },
                                            ),
                                        )
                                    },
                                    onClick = {
                                        menuOpen = false
                                        viewModel.toggleReaderMode()
                                    },
                                )
                            }
                            if (!state.showingArticle) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            stringResource(
                                                if (state.remoteContentAllowed) {
                                                    R.string.feed_hide_remote
                                                } else {
                                                    R.string.feed_show_remote
                                                },
                                            ),
                                        )
                                    },
                                    enabled = item.bodyHtml.isNotBlank(),
                                    onClick = {
                                        menuOpen = false
                                        viewModel.toggleRemoteContent()
                                    },
                                )
                            }
                            if (articleUrl != null) {
                                DropdownMenuItem(
                                    text = { Text(articleButtonLabel(state, online)) },
                                    onClick = {
                                        menuOpen = false
                                        viewModel.toggleArticle()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feed_open_in_browser)) },
                                    onClick = {
                                        menuOpen = false
                                        runCatching {
                                            context.startActivity(
                                                Intent(Intent.ACTION_VIEW, articleUrl.toUri()),
                                            )
                                        }
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feed_share_link)) },
                                    leadingIcon = { Icon(Icons.Default.Share, contentDescription = null) },
                                    onClick = {
                                        menuOpen = false
                                        val send =
                                            Intent(Intent.ACTION_SEND).apply {
                                                type = "text/plain"
                                                putExtra(Intent.EXTRA_TEXT, articleUrl)
                                                putExtra(Intent.EXTRA_SUBJECT, item.title)
                                            }
                                        runCatching { context.startActivity(Intent.createChooser(send, null)) }
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feed_copy_link)) },
                                    onClick = {
                                        menuOpen = false
                                        clipboard.setText(AnnotatedString(articleUrl))
                                    },
                                )
                            }
                        }
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            state.error?.let { message ->
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
            }
            if (!state.loaded) {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
            } else if (item != null) {
                if (state.showingArticle && articleUrl != null) {
                    ArticleWebView(
                        url = articleUrl,
                        profileName = state.subscription?.dataStoreUuid.orEmpty(),
                        online = online,
                        onLeave = viewModel::toggleArticle,
                        modifier = Modifier.fillMaxSize(),
                        wantsReader = state.readerMode,
                    )
                } else {
                    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Text(
                            item.title.ifBlank { stringResource(R.string.feed_untitled) },
                            style = MaterialTheme.typography.titleLarge,
                        )
                        if (articleUrl != null) {
                            val host = runCatching { articleUrl.toUri().host }.getOrNull()
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                TextButton(
                                    onClick = {
                                        runCatching {
                                            context.startActivity(
                                                Intent(Intent.ACTION_VIEW, articleUrl.toUri()),
                                            )
                                        }
                                    },
                                ) {
                                    Text(
                                        if (host.isNullOrEmpty()) {
                                            stringResource(R.string.feed_open_on_web)
                                        } else {
                                            stringResource(R.string.feed_open_on, host)
                                        },
                                    )
                                }
                                TextButton(
                                    onClick = viewModel::toggleArticle,
                                ) { Text(articleButtonLabel(state, online)) }
                            }
                        }
                        val caption =
                            listOf(
                                title,
                                item.author,
                                FeedItemDate.absolute(item.publishedAt),
                            ).filter { it.isNotBlank() }
                        Text(
                            caption.joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    HorizontalDivider()
                    if (item.bodyHtml.isBlank()) {
                        Column(modifier = Modifier.fillMaxWidth().padding(24.dp)) {
                            Text(
                                stringResource(R.string.feed_no_content_title),
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Text(
                                stringResource(R.string.feed_no_content_body),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    } else {
                        val darkMode = isSystemInDarkTheme()
                        HtmlBody(
                            html =
                                upgradeInsecureRequests(
                                    if (state.readerMode) readerModeHtml(item.bodyHtml, darkMode) else item.bodyHtml,
                                ),
                            allowRemoteContent = state.remoteContentAllowed,
                            onLinkTap = { url -> LinkMenuTarget.from(url)?.let { linkTarget = it } },
                            modifier = Modifier.fillMaxSize(),
                            restoreFraction = state.restoreFraction,
                            onScrollFraction = viewModel::recordScroll,
                        )
                    }
                }
            }
        }
    }

    linkTarget?.let { target ->
        LinkMenuSheet(target = target, onDismiss = { linkTarget = null })
    }
}

@Composable
private fun articleButtonLabel(
    state: FeedItemDetailUiState,
    online: Boolean,
): String =
    stringResource(
        when {
            state.showingArticle -> R.string.feed_show_feed_content
            !online -> R.string.feed_open_article_offline
            else -> R.string.feed_open_article
        },
    )
