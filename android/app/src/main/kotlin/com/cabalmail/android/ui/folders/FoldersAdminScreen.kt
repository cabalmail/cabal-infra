package com.cabalmail.android.ui.folders

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R

/**
 * Folder management (plan §6.2): every folder with its subscription state
 * as a switch, a per-folder menu (delete, for empty user folders), and a
 * "New folder" FAB with a name field and parent picker.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FoldersAdminScreen(
    state: FoldersAdminUiState,
    viewModel: FoldersAdminViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(state.error) {
        val message = state.error ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(message)
        viewModel.clearError()
    }
    var showCreate by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.folders_admin_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Default.Add, contentDescription = stringResource(R.string.folders_new))
            }
        },
    ) { innerPadding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier.padding(innerPadding).fillMaxSize(),
        ) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(state.folders.orEmpty(), key = { it }) { folder ->
                    val subscribed = folder in state.subscribed
                    val busy = folder in state.busy
                    ListItem(
                        headlineContent = { Text(folder) },
                        supportingContent = {
                            val count = state.counts[folder]
                            Text(
                                if (count != null) {
                                    pluralStringResource(R.plurals.folders_message_count, count, count)
                                } else {
                                    stringResource(
                                        if (subscribed) R.string.folders_subscribed else R.string.folders_unsubscribed,
                                    )
                                },
                            )
                        },
                        trailingContent = {
                            androidx.compose.foundation.layout.Row {
                                Switch(
                                    checked = subscribed,
                                    onCheckedChange = { viewModel.setSubscribed(folder, it) },
                                    enabled = !busy,
                                )
                                if (viewModel.canDelete(folder)) {
                                    IconButton(onClick = { menuFor = folder }) {
                                        Icon(
                                            Icons.Default.MoreVert,
                                            contentDescription = stringResource(R.string.more_actions),
                                        )
                                    }
                                    DropdownMenu(expanded = menuFor == folder, onDismissRequest = { menuFor = null }) {
                                        DropdownMenuItem(
                                            text = {
                                                Text(
                                                    stringResource(R.string.folders_delete),
                                                    color = MaterialTheme.colorScheme.error,
                                                )
                                            },
                                            onClick = {
                                                menuFor = null
                                                confirmingDelete = folder
                                            },
                                        )
                                    }
                                }
                            }
                        },
                    )
                    HorizontalDivider()
                }
            }
        }
    }

    if (showCreate) {
        NewFolderDialog(
            parents = state.folders.orEmpty(),
            creating = state.creating,
            onCreate = { name, parent -> viewModel.create(name, parent) { showCreate = false } },
            onDismiss = { showCreate = false },
        )
    }

    confirmingDelete?.let { folder ->
        AlertDialog(
            onDismissRequest = { confirmingDelete = null },
            title = { Text(stringResource(R.string.folders_delete_confirm_title)) },
            text = { Text(stringResource(R.string.folders_delete_confirm_body, folder)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDelete = null
                        viewModel.delete(folder)
                    },
                ) {
                    Text(stringResource(R.string.folders_delete), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewFolderDialog(
    parents: List<String>,
    creating: Boolean,
    onCreate: (name: String, parent: String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    var parent by rememberSaveable { mutableStateOf("") }
    var parentMenuOpen by remember { mutableStateOf(false) }
    val topLevel = stringResource(R.string.folders_parent_top_level)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.folders_new)) },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.replace("/", "") },
                    label = { Text(stringResource(R.string.folders_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                ExposedDropdownMenuBox(
                    expanded = parentMenuOpen,
                    onExpandedChange = { parentMenuOpen = it },
                    modifier = Modifier.padding(top = 8.dp),
                ) {
                    OutlinedTextField(
                        value = parent.ifEmpty { topLevel },
                        onValueChange = {},
                        readOnly = true,
                        label = { Text(stringResource(R.string.folders_parent)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = parentMenuOpen) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = parentMenuOpen, onDismissRequest = { parentMenuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(topLevel) },
                            onClick = {
                                parent = ""
                                parentMenuOpen = false
                            },
                        )
                        parents.forEach { candidate ->
                            DropdownMenuItem(
                                text = { Text(candidate) },
                                onClick = {
                                    parent = candidate
                                    parentMenuOpen = false
                                },
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onCreate(name, parent) }, enabled = name.isNotBlank() && !creating) {
                Text(stringResource(R.string.folders_create))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}
