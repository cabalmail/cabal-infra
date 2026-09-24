package com.cabalmail.android.ui.mail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.LocalLogoTint
import com.cabalmail.kit.models.FolderStatus
import com.cabalmail.kit.settings.FolderCountDisplay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderListScreen(
    state: FoldersUiState,
    onRefresh: () -> Unit,
    onOpenFolder: (String) -> Unit,
    onOpenSearch: () -> Unit,
    onEmptyTrash: () -> Unit,
    onCompose: () -> Unit,
    modifier: Modifier = Modifier,
    /** Silent refresh, driven every minute while resumed (plan §7.3). */
    onPoll: () -> Unit = {},
    /** What the per-folder badge shows (plan §6.3 "Folder count display"). */
    countDisplay: FolderCountDisplay = FolderCountDisplay.UNREAD,
    filter: FolderListFilter = FolderListFilter(),
    onFilter: (FolderFilterPill) -> Unit = {},
    /** Marks every message in the folder read, after the row's confirmation. */
    onMarkAllRead: (String) -> Unit = {},
) {
    ForegroundPolling(onPoll)

    Scaffold(
        modifier = modifier.fillMaxSize(),
        floatingActionButton = {
            FloatingActionButton(onClick = onCompose) {
                Icon(Icons.Default.Create, contentDescription = stringResource(R.string.compose_new))
            }
        },
        topBar = {
            TopAppBar(
                // The brand mark stands in for the title, as in the Apple
                // clients' sidebar; its drawable carries the display size.
                title = { BrandMark() },
                actions = {
                    IconButton(onClick = onOpenSearch) {
                        Icon(Icons.Default.Search, contentDescription = stringResource(R.string.search))
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            FolderFilterPills(filter = filter, onFilter = onFilter)
            PullToRefreshBox(
                isRefreshing = state.refreshing,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                FolderListContent(
                    state = state,
                    countDisplay = countDisplay,
                    filter = filter,
                    onOpenFolder = onOpenFolder,
                    onEmptyTrash = onEmptyTrash,
                    onMarkAllRead = onMarkAllRead,
                )
            }
        }
    }
}

/**
 * The leading pane of the wide-window three-pane mail layout (plan §7.2):
 * the same folder rows as [FolderListScreen] without its chrome — the
 * adjacent message list owns search and compose — and with the open
 * folder highlighted. The pane is recreated whenever the open folder
 * changes, so it starts its list at [scroll] and reports every move through
 * [onScrollChange] for the caller to keep.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPane(
    state: FoldersUiState,
    selectedFolder: String,
    onOpenFolder: (String) -> Unit,
    onEmptyTrash: () -> Unit,
    modifier: Modifier = Modifier,
    /** Silent refresh, driven every minute while resumed (plan §7.3). */
    onPoll: () -> Unit = {},
    countDisplay: FolderCountDisplay = FolderCountDisplay.UNREAD,
    filter: FolderListFilter = FolderListFilter(),
    onFilter: (FolderFilterPill) -> Unit = {},
    scroll: FolderPaneScroll = FolderPaneScroll(),
    onScrollChange: (FolderPaneScroll) -> Unit = {},
    onMarkAllRead: (String) -> Unit = {},
) {
    ForegroundPolling(onPoll)
    val listState = rememberLazyListState(scroll.index, scroll.offset)
    val latestOnScrollChange by rememberUpdatedState(onScrollChange)
    LaunchedEffect(listState) {
        snapshotFlow { FolderPaneScroll(listState.firstVisibleItemIndex, listState.firstVisibleItemScrollOffset) }
            .collect { latestOnScrollChange(it) }
    }

    Column(modifier = modifier.fillMaxSize()) {
        // A bar of its own keeps the rows aligned with the neighbouring
        // panes' content, under their top bars.
        TopAppBar(title = { BrandMark() })
        FolderFilterPills(filter = filter, onFilter = onFilter)
        FolderListContent(
            state = state,
            countDisplay = countDisplay,
            filter = filter,
            onOpenFolder = onOpenFolder,
            onEmptyTrash = onEmptyTrash,
            onMarkAllRead = onMarkAllRead,
            selectedFolder = selectedFolder,
            listState = listState,
        )
    }
}

@Composable
private fun BrandMark() {
    Icon(
        painterResource(R.drawable.cabalmail_mark),
        contentDescription = stringResource(R.string.app_name),
        tint = LocalLogoTint.current,
    )
}

/**
 * The filter row under the top bar, styled like the message list's pills.
 * Subscribed and Unread are independent toggles; All is the state with
 * both off (see [FolderListFilter]).
 */
@Composable
private fun FolderFilterPills(
    filter: FolderListFilter,
    onFilter: (FolderFilterPill) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        FolderFilterPill.entries.forEach { pill ->
            FilterChip(
                selected = filter.isOn(pill),
                onClick = { onFilter(pill) },
                label = { Text(stringResource(pill.labelRes())) },
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

private fun FolderFilterPill.labelRes(): Int =
    when (this) {
        FolderFilterPill.ALL -> R.string.filter_all
        FolderFilterPill.SUBSCRIBED -> R.string.folder_filter_subscribed
        FolderFilterPill.UNREAD -> R.string.filter_unread
    }

/** The folder rows shared by the full-screen list and the wide-window pane. */
@Composable
private fun FolderListContent(
    state: FoldersUiState,
    countDisplay: FolderCountDisplay,
    filter: FolderListFilter,
    onOpenFolder: (String) -> Unit,
    onEmptyTrash: () -> Unit,
    onMarkAllRead: (String) -> Unit,
    modifier: Modifier = Modifier,
    selectedFolder: String? = null,
    listState: LazyListState = rememberLazyListState(),
) {
    var confirmingEmptyTrash by remember { mutableStateOf(false) }
    // The folder whose mark-all-read confirmation is up, if any.
    var confirmingMarkAllRead by remember { mutableStateOf<String?>(null) }
    // The row whose long-press menu is open, by path; one at a time.
    var menuFor by remember { mutableStateOf<String?>(null) }

    val rows =
        FolderSections.rows(
            folders = state.folders.orEmpty(),
            subscribed = state.subscribed,
            statuses = state.statuses,
            filter = filter,
            selected = selectedFolder,
        )
    LazyColumn(state = listState, modifier = modifier.fillMaxSize()) {
        state.error?.let { message ->
            item {
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        items(rows, key = { it }) { folder ->
            FolderRow(
                folder = folder,
                status = state.statuses[folder],
                countDisplay = countDisplay,
                selected = folder == selectedFolder,
                onOpenFolder = onOpenFolder,
                onConfirmEmptyTrash = { confirmingEmptyTrash = true },
                onConfirmMarkAllRead = { confirmingMarkAllRead = folder },
                menuOpen = menuFor == folder,
                onMenuChange = { menuFor = if (it) folder else null },
            )
            HorizontalDivider()
        }
    }

    confirmingMarkAllRead?.let { folder ->
        MarkAllReadDialog(
            folder = folder,
            onDismiss = { confirmingMarkAllRead = null },
            onConfirm = {
                confirmingMarkAllRead = null
                onMarkAllRead(folder)
            },
        )
    }

    if (confirmingEmptyTrash) {
        AlertDialog(
            onDismissRequest = { confirmingEmptyTrash = false },
            title = { Text(stringResource(R.string.empty_trash)) },
            text = { Text(stringResource(R.string.empty_trash_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingEmptyTrash = false
                        onEmptyTrash()
                    },
                ) {
                    Text(stringResource(R.string.empty_trash), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingEmptyTrash = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

/**
 * One folder row: tap opens it, long-press opens its menu — Mark all as
 * read for every folder, plus Empty Trash on the Trash row, whose inline
 * button stays where it was so the row's footprint does not move.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FolderRow(
    folder: String,
    status: FolderStatus?,
    countDisplay: FolderCountDisplay,
    selected: Boolean,
    onOpenFolder: (String) -> Unit,
    onConfirmEmptyTrash: () -> Unit,
    onConfirmMarkAllRead: () -> Unit,
    menuOpen: Boolean,
    onMenuChange: (Boolean) -> Unit,
) {
    val menuLabel = stringResource(R.string.folder_row_menu, folder)
    Box {
        FolderListItem(
            folder = folder,
            status = status,
            countDisplay = countDisplay,
            selected = selected,
            onConfirmEmptyTrash = onConfirmEmptyTrash,
            modifier =
                Modifier.combinedClickable(
                    onClick = { onOpenFolder(folder) },
                    onLongClick = { onMenuChange(true) },
                    onLongClickLabel = menuLabel,
                ),
        )
        DropdownMenu(expanded = menuOpen, onDismissRequest = { onMenuChange(false) }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.mark_all_read)) },
                onClick = {
                    onMenuChange(false)
                    onConfirmMarkAllRead()
                },
            )
            if (folder == FoldersViewModel.TRASH_FOLDER) {
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.empty_trash), color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        onMenuChange(false)
                        onConfirmEmptyTrash()
                    },
                )
            }
        }
    }
}

@Composable
private fun FolderListItem(
    folder: String,
    status: FolderStatus?,
    countDisplay: FolderCountDisplay,
    selected: Boolean,
    onConfirmEmptyTrash: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ListItem(
        headlineContent = {
            Text(
                folder,
                color =
                    if (FolderSections.hasUnread(status)) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )
        },
        colors =
            if (selected) {
                ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
            } else {
                ListItemDefaults.colors()
            },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val badge = FolderSections.badge(countDisplay, status?.unseen ?: 0, status?.messages ?: 0)
                if (badge != null) {
                    Badge { Text(badge) }
                }
                if (folder == FoldersViewModel.TRASH_FOLDER) {
                    IconButton(onClick = onConfirmEmptyTrash) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = stringResource(R.string.empty_trash),
                            tint = MaterialTheme.colorScheme.error,
                        )
                    }
                }
            }
        },
        modifier = modifier,
    )
}

/**
 * The confirmation before a folder is marked read, naming the folder, as
 * the feed side's does for a feed or folder scope.
 */
@Composable
internal fun MarkAllReadDialog(
    folder: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.mark_all_read_title, folder)) },
        text = { Text(stringResource(R.string.mark_all_read_body)) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.mark_all_read_confirm)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}
