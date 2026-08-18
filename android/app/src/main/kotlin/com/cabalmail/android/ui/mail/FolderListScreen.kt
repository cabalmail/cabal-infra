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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderListScreen(
    state: FoldersUiState,
    onRefresh: () -> Unit,
    onOpenFolder: (String) -> Unit,
    onOpenSearch: () -> Unit,
    onEmptyTrash: () -> Unit,
    onSignOut: () -> Unit,
    onCompose: () -> Unit,
    modifier: Modifier = Modifier,
    /** A foreign-device resume cursor is available (plan §4.5). */
    resumeAvailable: Boolean = false,
    onResume: () -> Unit = {},
    onResumeDismiss: () -> Unit = {},
    /** An unsent local draft is available to reopen (plan §5.3). */
    localDraftAvailable: Boolean = false,
    onOpenLocalDraft: () -> Unit = {},
    onLocalDraftDismiss: () -> Unit = {},
) {
    var confirmingEmptyTrash by remember { mutableStateOf(false) }
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
    val localDraftMessage = stringResource(R.string.local_draft_prompt)
    val localDraftAction = stringResource(R.string.local_draft_resume)
    LaunchedEffect(localDraftAvailable) {
        if (localDraftAvailable) {
            val result =
                snackbarHostState.showSnackbar(
                    message = localDraftMessage,
                    actionLabel = localDraftAction,
                    withDismissAction = true,
                    duration = SnackbarDuration.Indefinite,
                )
            when (result) {
                SnackbarResult.ActionPerformed -> onOpenLocalDraft()
                SnackbarResult.Dismissed -> onLocalDraftDismiss()
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
                    TextButton(onClick = onSignOut) {
                        Text(stringResource(R.string.sign_out))
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
                                val unseen = state.statuses[folder]?.unseen ?: 0
                                if (unseen > 0) {
                                    Badge { Text(unseen.toString()) }
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
