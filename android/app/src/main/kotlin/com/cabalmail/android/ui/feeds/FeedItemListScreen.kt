package com.cabalmail.android.ui.feeds

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.ForegroundPolling
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.kit.compose.HtmlText
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssOrderingMode

/**
 * One feed list: sticky filter pills, the orderings in the overflow menu
 * (single-feed scopes), per-feed search, swipe to mark read or favorite,
 * a confirmed mark-all-read, the health header, and the older-items
 * footer gated on the server having more.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedItemListScreen(
    title: String,
    state: FeedItemListUiState,
    viewModel: FeedItemListViewModel,
    onOpenItem: (RssItem) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    /** The item open in an adjacent detail pane, if any. */
    highlightedId: String? = null,
    /** Opens the feed's settings sheet (single-feed scopes with a management model). */
    onOpenSettings: (() -> Unit)? = null,
) {
    ForegroundPolling(viewModel::poll, FEED_POLL_MS)
    var confirmMarkAllRead by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    val healthLevel = FeedHealth.level(state.subscription?.feed)
    val healthHeadline = FeedHealth.headline(state.subscription?.feed, healthLevel.summary())

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                            )
                        }
                    }
                },
                actions = {
                    IconButton(onClick = viewModel::sync, enabled = !state.syncing) {
                        Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.feed_refresh))
                    }
                    IconButton(onClick = { confirmMarkAllRead = true }, enabled = !state.allRead) {
                        Icon(Icons.Default.Email, contentDescription = stringResource(R.string.feed_mark_all_read))
                    }
                    if (state.canSearch) {
                        IconButton(onClick = { menuOpen = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.feed_order))
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            if (onOpenSettings != null) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feeds_feed_settings)) },
                                    onClick = {
                                        menuOpen = false
                                        onOpenSettings()
                                    },
                                )
                                HorizontalDivider()
                            }
                            RssOrderingMode.entries.forEach { ordering ->
                                DropdownMenuItem(
                                    text = { Text(ordering.label()) },
                                    trailingIcon = {
                                        if (state.ordering == ordering) {
                                            Icon(
                                                Icons.Default.Check,
                                                contentDescription = stringResource(R.string.active_option),
                                            )
                                        }
                                    },
                                    onClick = {
                                        menuOpen = false
                                        viewModel.setOrdering(ordering)
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
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                RssItemFilter.entries.forEach { filter ->
                    FilterChip(
                        selected = state.filter == filter,
                        onClick = { viewModel.setFilter(filter) },
                        label = { Text(filter.label()) },
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
            }
            if (state.canSearch) {
                OutlinedTextField(
                    value = state.searchQuery,
                    onValueChange = viewModel::setSearchQuery,
                    singleLine = true,
                    placeholder = { Text(stringResource(R.string.feed_search_hint)) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            PullToRefreshBox(
                isRefreshing = state.syncing,
                onRefresh = viewModel::sync,
                modifier = Modifier.fillMaxSize(),
            ) {
                FeedItemRows(
                    state = state,
                    healthHeadline = healthHeadline,
                    healthStopped = healthLevel == FeedHealthLevel.Stopped,
                    viewModel = viewModel,
                    onOpenItem = onOpenItem,
                    highlightedId = highlightedId,
                )
            }
        }
    }

    if (confirmMarkAllRead) {
        AlertDialog(
            onDismissRequest = { confirmMarkAllRead = false },
            title = { Text(stringResource(R.string.feed_mark_all_read_title, title)) },
            text = { Text(stringResource(R.string.feed_mark_all_read_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmMarkAllRead = false
                        viewModel.markAllRead()
                    },
                ) { Text(stringResource(R.string.feed_mark_all_read_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmMarkAllRead = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun FeedItemRows(
    state: FeedItemListUiState,
    healthHeadline: String?,
    healthStopped: Boolean,
    viewModel: FeedItemListViewModel,
    onOpenItem: (RssItem) -> Unit,
    highlightedId: String?,
) {
    val listState = rememberLazyListState()
    val anchor = remember { ListAnchor(epoch = state.listEpoch) }
    // Compose anchors a lazy list on the key of its first visible row and
    // follows that key when the rows change. Left alone, the list opens on
    // the footer — the only row until the first page arrives — and lands at
    // the bottom once the rows fill in above it (visible on an oldest-first
    // feed, where the newest rows are at the bottom); an ordering change
    // likewise follows the old top row to wherever it sorts. So a list that
    // begins from a new starting point (the epoch) opens at the top, and a
    // re-read of the same list (a sync, a poll) keeps the reader's place
    // except at the very top, which stays the top rather than sliding down
    // under the rows a newest-first sync puts above the previous first row.
    // A SideEffect runs as the composition applies, before the frame's
    // measure, and requestScrollToItem takes effect in that measure, so the
    // rows never paint at the wrong place first; the scroll position is read
    // there rather than in composition, which would recompose every row on
    // each scrolled pixel.
    val firstId = state.items.firstOrNull()?.id
    SideEffect {
        val restarted = state.listEpoch != anchor.epoch
        val atTop = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0
        if (restarted || (firstId != anchor.firstId && atTop)) listState.requestScrollToItem(0)
        anchor.epoch = state.listEpoch
        anchor.firstId = firstId
    }
    LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
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
        if (healthHeadline != null) {
            item(key = "health") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Icon(
                        Icons.Default.Warning,
                        contentDescription = null,
                        tint = if (healthStopped) ColorTokens.dangerFg() else ColorTokens.warningFg(),
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        healthHeadline,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
        }
        if (state.hasLoaded && state.items.isEmpty()) {
            item(key = "empty") { EmptyState(state) }
        }
        items(state.items, key = { it.id }) { item ->
            val isLast = item.id == state.items.lastOrNull()?.id
            LaunchedEffect(isLast, item.id) {
                if (isLast) viewModel.loadMore()
            }
            FeedSwipeRow(
                isRead = item.isRead,
                isFavorite = item.isFavorite,
                onToggleRead = { viewModel.setRead(item, !item.isRead) },
                onToggleFavorite = { viewModel.setFavorite(item, !item.isFavorite) },
                highlighted = item.id == highlightedId,
            ) {
                FeedItemRow(
                    item = item,
                    feedName = if (state.subscription == null) state.feedName(item) else null,
                    pending = item.id in state.pendingIds,
                    onClick = {
                        viewModel.didOpen(item)
                        onOpenItem(item)
                    },
                )
            }
            HorizontalDivider()
        }
        item(key = "footer") {
            OlderFooter(state = state, onLoadOlder = viewModel::loadOlder)
        }
    }
}

/** What the rows' SideEffect last saw: the list epoch and the first row's id. */
private class ListAnchor(
    var epoch: Int,
    var firstId: String? = null,
)

@Composable
private fun EmptyState(state: FeedItemListUiState) {
    val (title, body) =
        when {
            state.searchQuery.isNotBlank() ->
                stringResource(R.string.feed_empty_search_title) to stringResource(R.string.feed_empty_search_body)
            state.filter == RssItemFilter.UNREAD ->
                stringResource(R.string.feed_empty_unread_title) to stringResource(R.string.feed_empty_unread_body)
            state.filter == RssItemFilter.FAVORITE ->
                stringResource(R.string.feed_empty_favorite_title) to stringResource(R.string.feed_empty_favorite_body)
            else ->
                stringResource(if (state.syncing) R.string.feed_empty_all_syncing else R.string.feed_empty_all_title) to
                    stringResource(R.string.feed_empty_all_body)
        }
    Column(modifier = Modifier.fillMaxWidth().padding(24.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** "Load older items", or "Search older items" when a search found nothing cached; only while the server has more. */
@Composable
private fun OlderFooter(
    state: FeedItemListUiState,
    onLoadOlder: () -> Unit,
) {
    if (!state.canLoadOlder) return
    val searching = state.searchQuery.isNotBlank()
    if (searching && state.items.isNotEmpty()) return
    Row(
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(12.dp),
    ) {
        if (state.loadingOlder) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = ColorTokens.accentForestFg())
        } else {
            TextButton(onClick = onLoadOlder) {
                Text(stringResource(if (searching) R.string.feed_search_older else R.string.feed_load_older))
            }
        }
    }
}

/** Start-to-end toggles read, end-to-start toggles favorite; both settle the row back. */
@Composable
private fun FeedSwipeRow(
    isRead: Boolean,
    isFavorite: Boolean,
    onToggleRead: () -> Unit,
    onToggleFavorite: () -> Unit,
    highlighted: Boolean,
    content: @Composable () -> Unit,
) {
    val currentToggleRead by rememberUpdatedState(onToggleRead)
    val currentToggleFavorite by rememberUpdatedState(onToggleFavorite)
    // Same once-per-gesture latch as the mail rows (EnvelopeRow.SwipeRow).
    val fired = remember { mutableStateOf(false) }
    val swipeState =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                if (value != SwipeToDismissBoxValue.Settled && !fired.value) {
                    fired.value = true
                    when (value) {
                        SwipeToDismissBoxValue.StartToEnd -> currentToggleRead()
                        SwipeToDismissBoxValue.EndToStart -> currentToggleFavorite()
                        SwipeToDismissBoxValue.Settled -> Unit
                    }
                }
                false
            },
        )
    LaunchedEffect(swipeState) {
        snapshotFlow { swipeState.dismissDirection }.collect { direction ->
            if (direction == SwipeToDismissBoxValue.Settled) fired.value = false
        }
    }
    val rowColor =
        if (highlighted) {
            MaterialTheme.colorScheme.primary
                .copy(alpha = 0.12f)
                .compositeOver(MaterialTheme.colorScheme.surface)
        } else {
            MaterialTheme.colorScheme.surface
        }
    SwipeToDismissBox(
        state = swipeState,
        backgroundContent = {
            val toRead = swipeState.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            Box(
                contentAlignment = if (toRead) Alignment.CenterStart else Alignment.CenterEnd,
                modifier =
                    Modifier
                        .fillMaxSize()
                        .background(
                            if (toRead) MaterialTheme.colorScheme.secondaryContainer else ColorTokens.flaggedWash(),
                        ).padding(horizontal = 24.dp),
            ) {
                Icon(
                    if (toRead) Icons.Default.Email else Icons.Default.Star,
                    contentDescription =
                        stringResource(
                            when {
                                toRead && isRead -> R.string.mark_unread
                                toRead -> R.string.mark_read
                                isFavorite -> R.string.feed_unfavorite
                                else -> R.string.feed_favorite
                            },
                        ),
                )
            }
        },
    ) {
        Box(modifier = Modifier.background(rowColor)) { content() }
    }
}

/**
 * Unread dot, title, the first line of the body (when it has one), feed
 * name in multi-feed scopes, relative date, queued mark, favorite star.
 */
@Composable
internal fun FeedItemRow(
    item: RssItem,
    feedName: String?,
    pending: Boolean,
    onClick: () -> Unit,
) {
    val title = item.title.ifBlank { stringResource(R.string.feed_untitled) }
    val date = FeedItemDate.relative(item.publishedAt)
    // Cheap to derive: the scan stops at the first line of prose, not the
    // end of the body (see HtmlText.firstLine); remembered per body anyway.
    val snippet = remember(item.bodyHtml) { HtmlText.firstLine(item.bodyHtml) }
    val unreadText = stringResource(R.string.unread)
    val queuedText = stringResource(R.string.feed_change_queued)
    val favoriteText = stringResource(R.string.feed_favorite)
    // The row reads as one thing to a screen reader (and the tester's UI
    // dump), in the Apple rows' form: "Unread, <title>, <snippet>, <date>".
    val rowDescription =
        listOfNotNull(
            unreadText.takeIf { !item.isRead },
            title,
            snippet.ifEmpty { null },
            date.ifEmpty { null },
        ).joinToString(", ")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .semantics { contentDescription = rowDescription }
                .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Box(
            modifier =
                Modifier
                    .size(8.dp)
                    .background(if (item.isRead) Color.Transparent else ColorTokens.accentForestFg(), CircleShape)
                    .then(if (item.isRead) Modifier else Modifier.semantics { contentDescription = unreadText }),
        )
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (item.isRead) FontWeight.Normal else FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (snippet.isNotEmpty()) {
                // One line, cut with an ellipsis where it outruns the
                // column; an item with no prose keeps the two-line row.
                Text(
                    snippet,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                val caption = listOfNotNull(feedName?.takeIf { it.isNotEmpty() }, date.takeIf { it.isNotEmpty() })
                Text(
                    caption.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (pending) {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = queuedText,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 6.dp).size(14.dp),
                    )
                }
            }
        }
        if (item.isFavorite) {
            Icon(
                Icons.Default.Star,
                contentDescription = favoriteText,
                tint = ColorTokens.flaggedFg(),
                modifier = Modifier.padding(start = 8.dp).size(18.dp),
            )
        }
    }
}
