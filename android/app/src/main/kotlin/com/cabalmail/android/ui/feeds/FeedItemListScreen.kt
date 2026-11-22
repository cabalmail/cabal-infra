package com.cabalmail.android.ui.feeds

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.FlagMenuItem
import com.cabalmail.android.ui.mail.ForegroundPolling
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.android.ui.theme.FlagDot
import com.cabalmail.android.ui.theme.FlagDotMark
import com.cabalmail.android.ui.theme.FlagFilterChoice
import com.cabalmail.android.ui.theme.FlagFilterPill
import com.cabalmail.android.ui.theme.FlagMenu
import com.cabalmail.android.ui.theme.FlagToggle
import com.cabalmail.android.ui.theme.LocalFlagPalette
import com.cabalmail.android.ui.theme.LocalSwipeBindings
import com.cabalmail.android.ui.theme.SwipeReveal
import com.cabalmail.android.ui.theme.color
import com.cabalmail.android.ui.theme.feedSwipeReveal
import com.cabalmail.android.ui.theme.painter
import com.cabalmail.android.ui.theme.text
import com.cabalmail.kit.compose.HtmlText
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.settings.FeedSwipeAction
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * One feed list: the scope-switch menu behind the title, sticky filter
 * pills, the orderings in the overflow menu (single-feed scopes), per-feed
 * search, swipe to mark read or flag, a confirmed mark-all-read, the
 * health header, and the older-items footer gated on the server having
 * more.
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
    /**
     * The scope-switch menu behind the title (null until the feed tree has
     * loaded); picking a row calls [onSwitchScope] with its scope.
     */
    scopeMenu: List<FeedScopeMenuRow>? = null,
    onSwitchScope: (RssItemScope) -> Unit = {},
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
                title = {
                    FeedTitle(
                        title = title,
                        scope = state.scope,
                        menu = scopeMenu,
                        onSwitchScope = onSwitchScope,
                    )
                },
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
                FilterChip(
                    selected = state.unreadLit,
                    onClick = { viewModel.setFilter(FeedFlagWords.unreadTap(state.filter, state.flagPick)) },
                    label = { Text(RssItemFilter.UNREAD.label()) },
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
                // The Flagged pill is the built-in flag's remembered
                // filter, under the name that flag has in Settings > Flags.
                // Once the list holds a flag of the user's own it opens a
                // menu instead: every flag, Any flag and Clear filter
                // (FlagFilterMenu). A feed pill draws no count.
                FlagFilterPill(
                    palette = LocalFlagPalette.current,
                    builtInLit = state.builtInFlagLit,
                    pick = state.flagPick,
                    count = null,
                    onToggleBuiltIn = { viewModel.setFilter(state.filter.toggling(RssItemFilter.FAVORITE)) },
                    onChoose = { choice ->
                        when (choice) {
                            FlagFilterChoice.BuiltIn -> viewModel.setFilter(RssItemFilter.FAVORITE)
                            is FlagFilterChoice.Pick -> viewModel.pickFlag(choice.criterion)
                        }
                    },
                    onClear = { viewModel.setFilter(RssItemFilter.ALL) },
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
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

/**
 * The scope's name as a tappable affordance, the feed twin of the message
 * list's `FolderTitle`: a tap opens the scope-switch menu — All Feeds,
 * then the folder tree indented by depth with each folder's feeds beneath
 * it — and the current scope carries the check mark. Until the tree loads
 * the menu offers only the current scope, so the affordance never reads
 * as empty. Picking the current scope just closes the menu.
 */
@Composable
private fun FeedTitle(
    title: String,
    scope: RssItemScope,
    menu: List<FeedScopeMenuRow>?,
    onSwitchScope: (RssItemScope) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val rows = menu ?: listOf(FeedScopeMenuRow(scope = scope, title = title, depth = 0, isFolder = false))
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
                Modifier
                    .clip(MaterialTheme.shapes.small)
                    .clickable(onClickLabel = stringResource(R.string.feed_switch_scope)) { open = true }
                    .padding(horizontal = 4.dp),
        ) {
            Text(
                title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(Icons.Default.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            rows.forEach { row ->
                DropdownMenuItem(
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            // Indented by depth like the tree, with the feed
                            // glyph telling a feed from a folder at the same
                            // depth (the tree's chevron has no job here).
                            Spacer(modifier = Modifier.width((row.depth * 14).dp))
                            if (!row.isFolder && row.scope != RssItemScope.All) {
                                Icon(
                                    painterResource(R.drawable.ic_rss_feed),
                                    contentDescription = null,
                                    tint = ColorTokens.accentForestFg(),
                                    modifier = Modifier.padding(end = 8.dp).size(16.dp),
                                )
                            }
                            Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    },
                    trailingIcon = {
                        if (row.scope == scope) {
                            Icon(Icons.Default.Check, contentDescription = stringResource(R.string.active_option))
                        }
                    },
                    onClick = {
                        open = false
                        if (row.scope != scope) onSwitchScope(row.scope)
                    },
                )
            }
        }
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
    val palette = LocalFlagPalette.current
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
            // The flag swipe toggles the default flag, the first entry of
            // Settings > Flags, as a message's does.
            val flag = FlagToggle.defaultFlag(palette)
            val isFlagSet = item.carries(flag.slot)
            var menuOpen by remember(item.id) { mutableStateOf(false) }
            Box {
                FeedSwipeRow(
                    isRead = item.isRead,
                    flag = flag,
                    isFlagSet = isFlagSet,
                    onToggleRead = { viewModel.setRead(item, !item.isRead) },
                    onToggleFlag = { viewModel.setFlag(item, flag.slot, !isFlagSet) },
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
                        onLongClick = { menuOpen = true },
                    )
                }
                FeedItemRowMenu(
                    item = item,
                    palette = palette,
                    expanded = menuOpen,
                    onDismiss = { menuOpen = false },
                    onSetRead = { viewModel.setRead(item, it) },
                    onSetFlag = { slot, isSet -> viewModel.setFlag(item, slot, isSet) },
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
            state.unreadLit ->
                stringResource(R.string.feed_empty_unread_title) to stringResource(R.string.feed_empty_unread_body)
            state.builtInFlagLit || state.flagPick != null -> {
                // The words name the flag the pill is lit for, and offer
                // the swipe only while the swipe sets that flag.
                val palette = LocalFlagPalette.current
                val bindings = LocalSwipeBindings.current
                val offersSwipe =
                    FeedFlagWords.flaggedPillOffersSwipe(
                        palette = palette,
                        leading = bindings.feedLeading,
                        trailing = bindings.feedTrailing,
                        pick = state.flagPick,
                    )
                FeedFlagWords.emptyTitle(palette, state.flagPick).text() to
                    stringResource(
                        if (offersSwipe) R.string.feed_empty_favorite_body else R.string.feed_empty_favorite_body_menu,
                    )
            }
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
        horizontalArrangement = Arrangement.Center,
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

/**
 * Each edge performs the action the synced feed swipe preference binds to
 * it ([LocalSwipeBindings]; by default start-to-end toggles read and
 * end-to-start toggles the default flag, [flag], under its name and in its
 * color). An edge bound to [FeedSwipeAction.NONE] does not drag. Both
 * actions settle the row back.
 */
@Composable
internal fun FeedSwipeRow(
    isRead: Boolean,
    flag: FlagToggle,
    isFlagSet: Boolean,
    onToggleRead: () -> Unit,
    onToggleFlag: () -> Unit,
    highlighted: Boolean,
    content: @Composable () -> Unit,
) {
    val bindings = LocalSwipeBindings.current
    val currentToggleRead by rememberUpdatedState(onToggleRead)
    val currentToggleFlag by rememberUpdatedState(onToggleFlag)
    val reveal: (FeedSwipeAction) -> SwipeReveal? = { action ->
        feedSwipeReveal(action = action, isRead = isRead, flag = flag, isFlagSet = isFlagSet)
    }
    val perform: (FeedSwipeAction) -> Unit = { action ->
        when (action) {
            FeedSwipeAction.TOGGLE_READ -> currentToggleRead()
            FeedSwipeAction.TOGGLE_FAVORITE -> currentToggleFlag()
            FeedSwipeAction.NONE -> Unit
        }
    }
    // Same once-per-gesture latch as the mail rows (EnvelopeRow.SwipeRow).
    val fired = remember { mutableStateOf(false) }
    val swipeState =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                if (value != SwipeToDismissBoxValue.Settled && !fired.value) {
                    fired.value = true
                    when (value) {
                        SwipeToDismissBoxValue.StartToEnd -> perform(bindings.feedLeading)
                        SwipeToDismissBoxValue.EndToStart -> perform(bindings.feedTrailing)
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
        enableDismissFromStartToEnd = reveal(bindings.feedLeading) != null,
        enableDismissFromEndToStart = reveal(bindings.feedTrailing) != null,
        backgroundContent = {
            val leading = swipeState.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            val revealed = reveal(if (leading) bindings.feedLeading else bindings.feedTrailing)
            if (revealed != null) {
                Box(
                    contentAlignment = if (leading) Alignment.CenterStart else Alignment.CenterEnd,
                    modifier = Modifier.fillMaxSize().background(revealed.color()).padding(horizontal = 24.dp),
                ) {
                    Icon(revealed.painter(), contentDescription = revealed.label.text())
                }
            }
        },
    ) {
        Box(modifier = Modifier.background(rowColor)) { content() }
    }
}

/**
 * The row's long-press menu, the feed twin of a message row's: mark read
 * or unread, then the flags. One run of every flag in the order of
 * Settings > Flags, the built-in one included, each check-marked when the
 * item carries it, then any flag it carries whose entry was deleted
 * ([FlagMenu.rows]). When the default flag is all there is, the run is one
 * plain item: "Flag" / "Remove flag", or the flag's own name.
 */
@Composable
internal fun FeedItemRowMenu(
    item: RssItem,
    palette: List<FlagPaletteEntry>,
    expanded: Boolean,
    onDismiss: () -> Unit,
    onSetRead: (Boolean) -> Unit,
    onSetFlag: (String, Boolean) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = {
                Text(stringResource(if (item.isRead) R.string.feed_mark_as_unread else R.string.feed_mark_as_read))
            },
            onClick = {
                onDismiss()
                onSetRead(!item.isRead)
            },
        )
        val flagRows = FlagMenu.rows(palette, item.paletteFlags)
        if (FlagMenu.isOnlyTheDefault(flagRows, palette)) {
            val row = flagRows.single()
            DropdownMenuItem(
                text = { Text(FlagToggle(row.slot, row.label, row.color).title(row.isOn).text()) },
                onClick = {
                    onDismiss()
                    onSetFlag(row.slot, !row.isOn)
                },
            )
        } else {
            flagRows.forEach { row ->
                FlagMenuItem(row) {
                    onDismiss()
                    onSetFlag(row.slot, !row.isOn)
                }
            }
        }
    }
}

/**
 * Unread dot, title, the first line of the body (when it has one), feed
 * name in multi-feed scopes, relative date, queued mark, and a dot for
 * each flag the item carries, as a message's row draws them.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun FeedItemRow(
    item: RssItem,
    feedName: String?,
    pending: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    val title = item.title.ifBlank { stringResource(R.string.feed_untitled) }
    val date = FeedItemDate.relative(item.publishedAt)
    // Cheap to derive: the scan stops at the first line of prose, not the
    // end of the body (see HtmlText.firstLine); remembered per body anyway.
    val snippet = remember(item.bodyHtml) { HtmlText.firstLine(item.bodyHtml) }
    val unreadText = stringResource(R.string.unread)
    val queuedText = stringResource(R.string.feed_change_queued)
    // The built-in flag and the user's own, in the order, names and
    // colors of Settings > Flags, as a message's row draws them.
    val flagMarks = FlagDotMark.feedMarks(item, LocalFlagPalette.current)
    val rowDescription =
        feedRowDescription(
            unread = unreadText.takeIf { !item.isRead },
            title = title,
            snippet = snippet,
            date = date,
            flags = flagMarks.map { it.label },
        )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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
                // The flags' dots sit beside the date, as on a mail row.
                flagMarks.forEach { mark ->
                    FlagDot(mark, modifier = Modifier.padding(start = 6.dp))
                }
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
    }
}

/**
 * What a feed row says to a screen reader (and the tester's UI dump), in the
 * Apple rows' form: "Unread, <title>, <snippet>, <date>", then the name of
 * each flag the item carries. Pure, so it unit-tests without Compose.
 */
internal fun feedRowDescription(
    unread: String?,
    title: String,
    snippet: String,
    date: String,
    flags: List<String>,
): String = (listOf(unread.orEmpty(), title, snippet, date) + flags).filter { it.isNotEmpty() }.joinToString(", ")
