package com.cabalmail.android.ui.mail

import androidx.compose.foundation.clickable
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
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
    /** A foreign-device resume cursor is available (plan §4.5). */
    resumeAvailable: Boolean = false,
    onResume: () -> Unit = {},
    onResumeDismiss: () -> Unit = {},
) {
    var confirmingEmptyTrash by remember { mutableStateOf(false) }
    ForegroundPolling(onPoll)
    val snackbarHostState = remember { SnackbarHostState() }
    val resumeMessage = stringResource(R.string.resume_prompt)
    val resumeAction = stringResource(R.string.resume_action)
    LaunchedEffect(resumeAvailable) {
        if (resumeAvailable) {
            val result =
                snackbarHostState.showSnackbar(
                    message = resumeMessage,
                    actionLabel = resumeAction,
                    withDismissAction = true,
                    duration = SnackbarDuration.Indefinite,
                )
            when (result) {
                SnackbarResult.ActionPerformed -> onResume()
                SnackbarResult.Dismissed -> onResumeDismiss()
            }
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        floatingActionButton = {
            FloatingActionButton(onClick = onCompose) {
                Icon(Icons.Default.Create, contentDescription = stringResource(R.string.compose_new))
            }
        },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
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
            LazyColumn(modifier = Modifier.fillMaxSize()) {
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
