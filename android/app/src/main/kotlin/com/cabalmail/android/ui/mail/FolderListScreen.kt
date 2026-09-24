package com.cabalmail.android.ui.mail

import androidx.compose.foundation.clickable
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
 * Subscribed and Unread are independent toggles; both off is every folder
 * (see [FolderListFilter]).
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
    modifier: Modifier = Modifier,
    selectedFolder: String? = null,
    listState: LazyListState = rememberLazyListState(),
) {
    var confirmingEmptyTrash by remember { mutableStateOf(false) }

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
            )
            HorizontalDivider()
        }
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

@Composable
private fun FolderRow(
    folder: String,
    status: FolderStatus?,
    countDisplay: FolderCountDisplay,
    selected: Boolean,
    onOpenFolder: (String) -> Unit,
    onConfirmEmptyTrash: () -> Unit,
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
                val unseen = status?.unseen ?: 0
                val total = status?.messages ?: 0
                val badge =
                    when (countDisplay) {
                        FolderCountDisplay.UNREAD -> unseen.takeIf { it > 0 }?.toString()
                        FolderCountDisplay.TOTAL -> total.takeIf { it > 0 }?.toString()
                        FolderCountDisplay.BOTH ->
                            if (total > 0) "$unseen / $total" else null
                    }
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
        modifier = Modifier.clickable { onOpenFolder(folder) },
    )
}
