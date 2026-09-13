package com.cabalmail.android.ui.feeds

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Badge
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.ForegroundPolling
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.kit.models.RssItemScope

/** The feeds refresh while the app is open, as on Apple; background refresh waits for phase 8. */
const val FEED_POLL_MS = 15 * 60_000L

/**
 * The Feeds destination on a phone: the folder tree with feeds as leaves,
 * unread badges rolled up per folder, health marks, and an All Feeds row.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedListScreen(
    state: FeedsUiState,
    collapsed: Set<String>,
    onToggleCollapsed: (String) -> Unit,
    onRefresh: () -> Unit,
    onPoll: () -> Unit,
    onOpenScope: (RssItemScope) -> Unit,
    modifier: Modifier = Modifier,
) {
    ForegroundPolling(onPoll, FEED_POLL_MS)
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.feeds_title)) },
                actions = {
                    IconButton(onClick = onRefresh, enabled = !state.refreshing) {
                        Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.feeds_refresh))
                    }
                },
            )
        },
    ) { innerPadding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = onRefresh,
            modifier = Modifier.padding(innerPadding).fillMaxSize(),
        ) {
            FeedTreeContent(
                state = state,
                collapsed = collapsed,
                onToggleCollapsed = onToggleCollapsed,
                onOpenScope = onOpenScope,
            )
        }
    }
}

/**
 * The leading pane of the wide-window feeds layout: the same rows as
 * [FeedListScreen] without its chrome, with the open scope highlighted.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedPane(
    state: FeedsUiState,
    collapsed: Set<String>,
    selectedScope: RssItemScope?,
    onToggleCollapsed: (String) -> Unit,
    onOpenScope: (RssItemScope) -> Unit,
    onPoll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ForegroundPolling(onPoll, FEED_POLL_MS)
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(title = { Text(stringResource(R.string.feeds_title)) })
        FeedTreeContent(
            state = state,
            collapsed = collapsed,
            onToggleCollapsed = onToggleCollapsed,
            onOpenScope = onOpenScope,
            selectedScope = selectedScope,
        )
    }
}

@Composable
private fun FeedTreeContent(
    state: FeedsUiState,
    collapsed: Set<String>,
    onToggleCollapsed: (String) -> Unit,
    onOpenScope: (RssItemScope) -> Unit,
    modifier: Modifier = Modifier,
    selectedScope: RssItemScope? = null,
) {
    val rows = FeedTree.rows(state.folders, state.subscriptions, state.unreadCounts, collapsed)
    LazyColumn(modifier = modifier.fillMaxSize()) {
        state.error?.let { message ->
            item(key = "error") {
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        item(key = "all") {
            FeedTreeRowItem(
                row =
                    FeedTreeRow(
                        id = "all",
                        scope = RssItemScope.All,
                        title = stringResource(R.string.feeds_all),
                        depth = 0,
                        isFolder = false,
                        hasChildren = false,
                        unread = FeedTree.totalUnread(state.unreadCounts),
                    ),
                iconRes = R.drawable.ic_rss_feed,
                selected = selectedScope == RssItemScope.All,
                collapsed = false,
                onToggleCollapsed = {},
                onOpen = { onOpenScope(RssItemScope.All) },
            )
            HorizontalDivider()
        }
        if (state.hasLoaded && !state.hasSubscriptions) {
            item(key = "empty") {
                Column(modifier = Modifier.fillMaxWidth().padding(24.dp)) {
                    Text(stringResource(R.string.feeds_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(
                        stringResource(R.string.feeds_empty_body),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else if (!state.hasLoaded) {
            item(key = "loading") {
                Text(
                    stringResource(R.string.feeds_loading),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        items(rows, key = { it.id }) { row ->
            val folderId = (row.scope as? RssItemScope.Folder)?.folderId
            FeedTreeRowItem(
                row = row,
                iconRes = null,
                selected = selectedScope == row.scope,
                collapsed = folderId != null && folderId in collapsed,
                onToggleCollapsed = { folderId?.let(onToggleCollapsed) },
                onOpen = { onOpenScope(row.scope) },
            )
            HorizontalDivider()
        }
    }
}

@Composable
private fun FeedTreeRowItem(
    row: FeedTreeRow,
    iconRes: Int?,
    selected: Boolean,
    collapsed: Boolean,
    onToggleCollapsed: () -> Unit,
    onOpen: () -> Unit,
) {
    val level = FeedHealth.level(row.subscription?.feed)
    val healthSummary = level.summary()
    val unreadText = unreadLabel(row.unread)
    ListItem(
        headlineContent = {
            Text(
                row.title,
                maxLines = 1,
                color =
                    if (row.unread > 0 || selected) {
                        MaterialTheme.colorScheme.onSurface
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )
        },
        leadingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Spacer(modifier = Modifier.width((row.depth * 14).dp))
                if (row.isFolder) {
                    val rotation by animateFloatAsState(if (collapsed) 0f else 90f, label = "chevron")
                    val actionLabel =
                        stringResource(if (collapsed) R.string.feeds_expand else R.string.feeds_collapse, row.title)
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = actionLabel,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier =
                            Modifier
                                .alpha(if (row.hasChildren) 1f else 0f)
                                .rotate(rotation)
                                .clickable(
                                    enabled = row.hasChildren,
                                    onClickLabel = actionLabel,
                                    onClick = onToggleCollapsed,
                                ),
                    )
                } else {
                    Icon(
                        painterResource(iconRes ?: R.drawable.ic_rss_feed),
                        contentDescription = null,
                        tint = ColorTokens.accentForestFg(),
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (healthSummary != null) {
                    Icon(
                        Icons.Default.Warning,
                        contentDescription = healthSummary,
                        tint =
                            if (level == FeedHealthLevel.Stopped) ColorTokens.dangerFg() else ColorTokens.warningFg(),
                        modifier = Modifier.padding(end = 8.dp).size(18.dp),
                    )
                }
                if (row.unread > 0) {
                    Badge(modifier = Modifier.semantics { contentDescription = unreadText }) {
                        Text(row.unread.toString())
                    }
                }
            }
        },
        colors =
            if (selected) {
                ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
            } else {
                ListItemDefaults.colors()
            },
        modifier = Modifier.clickable(onClick = onOpen),
    )
    Box {}
}
