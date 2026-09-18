package com.cabalmail.android.ui.feeds

import android.content.Intent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Badge
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.ForegroundPolling
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription

/** The feeds refresh while the app is open, as on Apple; background refresh waits for phase 8. */
const val FEED_POLL_MS = 15 * 60_000L

/**
 * The Feeds destination on a phone: the folder tree with feeds as leaves,
 * unread badges rolled up per folder, health marks, an All Feeds row, the
 * add menu, and long-press management menus on the rows.
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
    /** Null until the management model exists; the add menu and row menus are hidden without it. */
    management: FeedManagementViewModel? = null,
    /** Replaces the collapsed set wholesale (expand all / collapse all). */
    onSetCollapsed: (Set<String>) -> Unit = {},
    /** The Unread pill (versus All), persisted per device. */
    unreadOnly: Boolean = true,
    onUnreadOnly: (Boolean) -> Unit = {},
) {
    ForegroundPolling(onPoll, FEED_POLL_MS)
    val snackbarHostState = remember { SnackbarHostState() }
    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.feeds_title)) },
                actions = {
                    if (management != null) {
                        FeedAddMenu(management)
                        FeedExportButton(management)
                    }
                    IconButton(onClick = onRefresh, enabled = !state.refreshing) {
                        Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.feeds_refresh))
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            FeedFilterPills(
                state = state,
                unreadOnly = unreadOnly,
                onUnreadOnly = onUnreadOnly,
                onSetCollapsed = onSetCollapsed,
            )
            PullToRefreshBox(
                isRefreshing = state.refreshing,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                FeedTreeContent(
                    state = state,
                    collapsed = collapsed,
                    unreadOnly = unreadOnly,
                    onToggleCollapsed = onToggleCollapsed,
                    onOpenScope = onOpenScope,
                    management = management,
                )
            }
        }
    }
    if (management != null) {
        FeedManagementSheets(
            viewModel = management,
            snackbarHostState = snackbarHostState,
            onSubscribed = { onOpenScope(RssItemScope.Subscription(it.subscriptionId)) },
        )
    }
}

/**
 * The leading pane of the wide-window feeds layout: the same rows as
 * [FeedListScreen] without its chrome, with the open scope highlighted.
 * The sheets are hosted by the layout around it. The pane is recreated
 * whenever the open scope changes, so it starts its list at [scroll] and
 * reports every move through [onScrollChange] for the caller to keep.
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
    management: FeedManagementViewModel? = null,
    scroll: FeedTreeScroll = FeedTreeScroll(),
    onScrollChange: (FeedTreeScroll) -> Unit = {},
    onSetCollapsed: (Set<String>) -> Unit = {},
    unreadOnly: Boolean = true,
    onUnreadOnly: (Boolean) -> Unit = {},
) {
    ForegroundPolling(onPoll, FEED_POLL_MS)
    val listState = rememberLazyListState(scroll.index, scroll.offset)
    val latestOnScrollChange by rememberUpdatedState(onScrollChange)
    LaunchedEffect(listState) {
        snapshotFlow { FeedTreeScroll(listState.firstVisibleItemIndex, listState.firstVisibleItemScrollOffset) }
            .collect { latestOnScrollChange(it) }
    }
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(R.string.feeds_title)) },
            actions = {
                if (management != null) {
                    FeedAddMenu(management)
                    FeedExportButton(management)
                }
            },
        )
        FeedFilterPills(
            state = state,
            unreadOnly = unreadOnly,
            onUnreadOnly = onUnreadOnly,
            onSetCollapsed = onSetCollapsed,
        )
        FeedTreeContent(
            state = state,
            collapsed = collapsed,
            unreadOnly = unreadOnly,
            onToggleCollapsed = onToggleCollapsed,
            onOpenScope = onOpenScope,
            selectedScope = selectedScope,
            management = management,
            listState = listState,
        )
    }
}

/**
 * The filter row under the top bar, styled like the message list's pills:
 * All and Unread as a radio, with expand-all / collapse-all at the
 * trailing edge. Both buttons disable when no folder has anything to fold.
 */
@Composable
private fun FeedFilterPills(
    state: FeedsUiState,
    unreadOnly: Boolean,
    onUnreadOnly: (Boolean) -> Unit,
    onSetCollapsed: (Set<String>) -> Unit,
) {
    val collapsible = FeedTree.collapsibleFolderIds(state.folders, state.subscriptions)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
    ) {
        FilterChip(
            selected = !unreadOnly,
            onClick = { onUnreadOnly(false) },
            label = { Text(stringResource(R.string.filter_all)) },
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        FilterChip(
            selected = unreadOnly,
            onClick = { onUnreadOnly(true) },
            label = { Text(stringResource(R.string.filter_unread)) },
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        Spacer(modifier = Modifier.weight(1f))
        IconButton(onClick = { onSetCollapsed(emptySet()) }, enabled = collapsible.isNotEmpty()) {
            Icon(
                painterResource(R.drawable.ic_unfold_more),
                contentDescription = stringResource(R.string.feeds_expand_all),
            )
        }
        IconButton(onClick = { onSetCollapsed(collapsible) }, enabled = collapsible.isNotEmpty()) {
            Icon(
                painterResource(R.drawable.ic_unfold_less),
                contentDescription = stringResource(R.string.feeds_collapse_all),
            )
        }
    }
}

/** The `+` menu: subscribe, new folder, and the OPML actions. */
@Composable
private fun FeedAddMenu(management: FeedManagementViewModel) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.feeds_add))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.feeds_subscribe)) },
                onClick = {
                    open = false
                    management.openSubscribe()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.feeds_new_folder)) },
                onClick = {
                    open = false
                    management.openNewFolder()
                },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.feeds_import_opml)) },
                onClick = {
                    open = false
                    management.requestImport()
                },
            )
        }
    }
}

/**
 * Export OPML beside the `+` menu: the one collection action that takes
 * something out, so it gets the share glyph rather than a place among the
 * add items. A plain button, not a one-item menu.
 */
@Composable
private fun FeedExportButton(management: FeedManagementViewModel) {
    IconButton(onClick = { management.exportOpml() }) {
        Icon(Icons.Default.Share, contentDescription = stringResource(R.string.feeds_export_opml))
    }
}

@Composable
private fun FeedTreeContent(
    state: FeedsUiState,
    collapsed: Set<String>,
    unreadOnly: Boolean,
    onToggleCollapsed: (String) -> Unit,
    onOpenScope: (RssItemScope) -> Unit,
    modifier: Modifier = Modifier,
    selectedScope: RssItemScope? = null,
    management: FeedManagementViewModel? = null,
    listState: LazyListState = rememberLazyListState(),
) {
    val rows =
        FeedTree.rows(
            state.folders,
            state.subscriptions,
            state.unreadCounts,
            collapsed,
            unreadOnly = unreadOnly,
            keep = selectedScope,
        )
    // The row whose long-press menu is open, by row id; one at a time.
    var menuFor by remember { mutableStateOf<String?>(null) }
    val allFeedsTitle = stringResource(R.string.feeds_all)
    LazyColumn(state = listState, modifier = modifier.fillMaxSize()) {
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
            val row =
                FeedTreeRow(
                    id = "all",
                    scope = RssItemScope.All,
                    title = allFeedsTitle,
                    depth = 0,
                    isFolder = false,
                    hasChildren = false,
                    unread = FeedTree.totalUnread(state.unreadCounts),
                )
            FeedTreeRowItem(
                row = row,
                selected = selectedScope == RssItemScope.All,
                collapsed = false,
                onToggleCollapsed = {},
                onOpen = { onOpenScope(RssItemScope.All) },
                menuOpen = menuFor == row.id,
                onMenuChange = { menuFor = if (it) row.id else null },
                management = management,
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
                    if (management != null) {
                        TextButton(onClick = { management.openSubscribe() }) {
                            Text(stringResource(R.string.feeds_subscribe_empty))
                        }
                    }
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
                selected = selectedScope == row.scope,
                collapsed = folderId != null && folderId in collapsed,
                onToggleCollapsed = { folderId?.let(onToggleCollapsed) },
                onOpen = { onOpenScope(row.scope) },
                menuOpen = menuFor == row.id,
                onMenuChange = { menuFor = if (it) row.id else null },
                management = management,
            )
            HorizontalDivider()
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FeedTreeRowItem(
    row: FeedTreeRow,
    selected: Boolean,
    collapsed: Boolean,
    onToggleCollapsed: () -> Unit,
    onOpen: () -> Unit,
    menuOpen: Boolean,
    onMenuChange: (Boolean) -> Unit,
    management: FeedManagementViewModel?,
) {
    val level = FeedHealth.level(row.subscription?.feed)
    val healthSummary = level.summary()
    val unreadText = unreadLabel(row.unread)
    val menuLabel = stringResource(R.string.feeds_row_menu, row.title)
    Box {
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
                            painterResource(R.drawable.ic_rss_feed),
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
                                if (level ==
                                    FeedHealthLevel.Stopped
                                ) {
                                    ColorTokens.dangerFg()
                                } else {
                                    ColorTokens.warningFg()
                                },
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
            modifier =
                Modifier.combinedClickable(
                    onClick = onOpen,
                    onLongClick = if (management != null) ({ onMenuChange(true) }) else null,
                    onLongClickLabel = menuLabel,
                ),
        )
        if (management != null) {
            FeedRowMenu(
                row = row,
                open = menuOpen,
                onDismiss = { onMenuChange(false) },
                management = management,
            )
        }
    }
}

/** The long-press menu: per folder, per feed, or Mark All as Read alone for All Feeds. */
@Composable
private fun FeedRowMenu(
    row: FeedTreeRow,
    open: Boolean,
    onDismiss: () -> Unit,
    management: FeedManagementViewModel,
) {
    val context = LocalContext.current
    val subscription: RssSubscription? = row.subscription
    val folderId = (row.scope as? RssItemScope.Folder)?.folderId
    DropdownMenu(expanded = open, onDismissRequest = onDismiss) {
        when {
            folderId != null -> {
                MenuEntry(
                    stringResource(R.string.feeds_subscribe_here),
                    onDismiss,
                ) { management.openSubscribe(folderId) }
                MenuEntry(
                    stringResource(R.string.feeds_new_folder_inside),
                    onDismiss,
                ) { management.openNewFolder(folderId) }
                HorizontalDivider()
                MenuEntry(stringResource(R.string.feeds_rename_or_move), onDismiss) {
                    management.openEditFolderById(folderId)
                }
                MenuEntry(stringResource(R.string.feed_mark_all_read), onDismiss) {
                    management.confirm(FeedConfirm.MarkAllRead(row.scope, row.title))
                }
                HorizontalDivider()
                MenuEntry(stringResource(R.string.feeds_delete_folder), onDismiss, destructive = true) {
                    management.confirmDeleteFolderById(folderId)
                }
            }
            subscription != null -> {
                MenuEntry(
                    stringResource(R.string.feeds_feed_settings),
                    onDismiss,
                ) { management.openSettings(subscription) }
                MenuEntry(stringResource(R.string.feed_mark_all_read), onDismiss) {
                    management.confirm(FeedConfirm.MarkAllRead(row.scope, row.title))
                }
                val site = subscription.feed?.siteUrl.orEmpty()
                if (site.isNotEmpty()) {
                    MenuEntry(stringResource(R.string.feeds_open_site), onDismiss) {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, site.toUri())) }
                    }
                }
                HorizontalDivider()
                MenuEntry(stringResource(R.string.feeds_unsubscribe), onDismiss, destructive = true) {
                    management.confirm(FeedConfirm.Unsubscribe(subscription))
                }
            }
            else ->
                MenuEntry(stringResource(R.string.feed_mark_all_read), onDismiss) {
                    management.confirm(FeedConfirm.MarkAllRead(row.scope, row.title))
                }
        }
    }
}

/** One menu row; closes the menu first, then acts. */
@Composable
private fun MenuEntry(
    label: String,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
    action: () -> Unit,
) {
    DropdownMenuItem(
        text = {
            Text(
                label,
                color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
            )
        },
        onClick = {
            onDismiss()
            action()
        },
    )
}
