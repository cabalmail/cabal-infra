package com.cabalmail.android.ui.mail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.models.Envelope

/**
 * The cross-folder search scope (plan §4.2a). Results reuse the message
 * row; each carries its source folder so taps and swipes route correctly.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(
    state: SearchUiState,
    viewModel: SearchViewModel,
    bimiLookup: suspend (String) -> String?,
    onOpenMessage: (Envelope) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pendingPurge by remember { mutableStateOf<Envelope?>(null) }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = {
                    TextField(
                        value = state.query,
                        onValueChange = viewModel::setQuery,
                        placeholder = { Text(stringResource(R.string.search_hint)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { viewModel.search() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.setShowFilters(true) }) {
                        Icon(
                            Icons.AutoMirrored.Filled.List,
                            contentDescription = stringResource(R.string.search_filters),
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        LazyColumn(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
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
            if (state.searched && !state.searching && state.results.isEmpty() && state.error == null) {
                item {
                    Text(
                        text = stringResource(R.string.search_no_results),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.outline,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            items(state.results, key = { "${it.folder}/${it.id}" }) { envelope ->
                SwipeRow(
                    isSeen = envelope.isSeen,
                    onToggleSeen = { viewModel.toggleSeen(envelope) },
                    onDispose = {
                        if (envelope.folder == "Trash") {
                            pendingPurge = envelope
                        } else {
                            viewModel.dispose(envelope)
                        }
                    },
                ) {
                    EnvelopeRow(
                        envelope = envelope,
                        onClick = { onOpenMessage(envelope) },
                        onLongClick = { viewModel.toggleFlag(envelope) },
                        folderLabel = envelope.folder,
                        bimiLookup = bimiLookup,
                    )
                }
                HorizontalDivider()
            }
            if (state.searching || state.cursor != null) {
                item {
                    if (state.searching) {
                        CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                    } else {
                        // Reaching this sentinel row pulls the next page.
                        LaunchedEffect(state.cursor) { viewModel.loadMore() }
                        Text(
                            text = stringResource(R.string.search_loading_more),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.outline,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                }
            }
        }
    }

    if (state.showFilters) {
        SearchFilterSheet(state = state, viewModel = viewModel)
    }

    pendingPurge?.let { envelope ->
        PurgeConfirmDialog(
            count = 1,
            onConfirm = {
                viewModel.dispose(envelope)
                pendingPurge = null
            },
            onDismiss = { pendingPurge = null },
        )
    }
}

/** The structured predicates `/search_envelopes` accepts (plan §4.2a). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SearchFilterSheet(
    state: SearchUiState,
    viewModel: SearchViewModel,
) {
    ModalBottomSheet(onDismissRequest = { viewModel.setShowFilters(false) }) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp),
        ) {
            Text(
                text = stringResource(R.string.search_filters),
                style = MaterialTheme.typography.titleMedium,
            )
            OutlinedTextField(
                value = state.filters.from.orEmpty(),
                onValueChange = { value -> viewModel.updateFilters { it.copy(from = value) } },
                label = { Text(stringResource(R.string.search_from)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.filters.to.orEmpty(),
                onValueChange = { value -> viewModel.updateFilters { it.copy(to = value) } },
                label = { Text(stringResource(R.string.search_to)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.filters.subject.orEmpty(),
                onValueChange = { value -> viewModel.updateFilters { it.copy(subject = value) } },
                label = { Text(stringResource(R.string.search_subject)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = state.filters.since.orEmpty(),
                    onValueChange = { value -> viewModel.updateFilters { it.copy(since = value) } },
                    label = { Text(stringResource(R.string.search_since)) },
                    placeholder = { Text(stringResource(R.string.search_date_hint)) },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = state.filters.before.orEmpty(),
                    onValueChange = { value -> viewModel.updateFilters { it.copy(before = value) } },
                    label = { Text(stringResource(R.string.search_before)) },
                    placeholder = { Text(stringResource(R.string.search_date_hint)) },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
            }
            LabeledCheckbox(
                label = stringResource(R.string.filter_unread),
                checked = state.filters.unread,
                onChange = { value -> viewModel.updateFilters { it.copy(unread = value) } },
            )
            LabeledCheckbox(
                label = stringResource(R.string.filter_flagged),
                checked = state.filters.flagged,
                onChange = { value -> viewModel.updateFilters { it.copy(flagged = value) } },
            )
            LabeledCheckbox(
                label = stringResource(R.string.search_has_attachment),
                checked = state.filters.hasAttachment,
                onChange = { value -> viewModel.updateFilters { it.copy(hasAttachment = value) } },
            )
            viewModel.scopeFolder?.let { folder ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = state.folderOnly, onCheckedChange = viewModel::setFolderOnly)
                    Text(
                        text = stringResource(R.string.search_this_folder_only, folder),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
            Row(
                horizontalArrangement = Arrangement.End,
                modifier = Modifier.fillMaxWidth(),
            ) {
                TextButton(onClick = { viewModel.setShowFilters(false) }) {
                    Text(stringResource(R.string.cancel))
                }
                TextButton(onClick = viewModel::search) {
                    Text(stringResource(R.string.search))
                }
            }
        }
    }
}

@Composable
private fun LabeledCheckbox(
    label: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked = checked, onCheckedChange = onChange)
        Text(text = label, style = MaterialTheme.typography.bodyMedium)
    }
}
