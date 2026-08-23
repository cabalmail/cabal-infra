package com.cabalmail.android.ui.mail

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.LocalLogoTint
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
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = onRefresh,
            modifier = Modifier.padding(innerPadding).fillMaxSize(),
        ) {
            FolderListContent(
                state = state,
                countDisplay = countDisplay,
                onOpenFolder = onOpenFolder,
                onEmptyTrash = onEmptyTrash,
            )
        }
    }
}

/**
 * The leading pane of the wide-window three-pane mail layout (plan §7.2):
 * the same folder rows as [FolderListScreen] without its chrome — the
 * adjacent message list owns search and compose — and with the open
 * folder highlighted.
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
) {
    ForegroundPolling(onPoll)

    Column(modifier = modifier.fillMaxSize()) {
        // A bar of its own keeps the rows aligned with the neighbouring
        // panes' content, under their top bars.
        TopAppBar(title = { BrandMark() })
        FolderListContent(
            state = state,
            countDisplay = countDisplay,
            onOpenFolder = onOpenFolder,
            onEmptyTrash = onEmptyTrash,
            selectedFolder = selectedFolder,
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

/** The folder rows shared by the full-screen list and the wide-window pane. */
@Composable
private fun FolderListContent(
    state: FoldersUiState,
    countDisplay: FolderCountDisplay,
    onOpenFolder: (String) -> Unit,
    onEmptyTrash: () -> Unit,
    modifier: Modifier = Modifier,
    selectedFolder: String? = null,
) {
    var confirmingEmptyTrash by remember { mutableStateOf(false) }

    LazyColumn(modifier = modifier.fillMaxSize()) {
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
        items(state.folders.orEmpty(), key = { it }) { folder ->
            ListItem(
                headlineContent = { Text(folder) },
                colors =
                    if (folder == selectedFolder) {
                        ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
                    } else {
                        ListItemDefaults.colors()
                    },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val status = state.statuses[folder]
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
                            IconButton(onClick = { confirmingEmptyTrash = true }) {
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
