package com.cabalmail.android.ui.mail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.MailOutline
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.Shortcut
import com.cabalmail.android.ui.theme.disposeIconPainter
import com.cabalmail.android.ui.theme.disposeLabelRes
import com.cabalmail.kit.models.Envelope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageListScreen(
    folder: String,
    state: MessageListUiState,
    viewModel: MessageListViewModel,
    bimiLookup: suspend (String) -> String?,
    /** Deployment mail domains, for the row's delivered-to address. */
    mailDomains: List<String>,
    onOpenMessage: (Envelope) -> Unit,
    onOpenSearch: () -> Unit,
    onBack: () -> Unit,
    onCompose: () -> Unit,
    modifier: Modifier = Modifier,
    /** False when a side-by-side reader owns the keyboard chords (plan §7.2). */
    handleShortcuts: Boolean = true,
    /** The message open in an adjacent detail pane, if any. */
    highlightedUid: Long? = null,
) {
    val listState = rememberLazyListState()
    ForegroundPolling(viewModel::poll)

    // Keyboard row cursor (plan §7.2): j/k (or the arrows) move it, Enter
    // opens it, and Ctrl+Shift+U / Ctrl+Shift+L act on it. Plain letters
    // only reach here while the list holds focus, so text fields keep theirs.
    var cursor by remember(state.filter) { mutableStateOf<Int?>(null) }
    val rowCount = if (state.filter == MessageFilter.ALL) state.total ?: 0 else state.filteredRows.size

    // Reads the view model's live state so the shortcut collector (a
    // long-lived coroutine) never acts on the parameter it captured.
    fun envelopeAt(index: Int?): Envelope? =
        index?.let {
            val live = viewModel.state.value
            if (live.filter == MessageFilter.ALL) live.envelopes[it] else live.filteredRows.getOrNull(it)
        }
    val scope = rememberCoroutineScope()

    fun moveCursor(delta: Int) {
        if (rowCount == 0) {
            return
        }
        val next = ((cursor ?: -1) + delta).coerceIn(0, rowCount - 1)
        cursor = next
        scope.launch { listState.animateScrollToItem(next) }
    }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focusRequester.requestFocus() } }
    val container = viewModel.container
    LaunchedEffect(handleShortcuts) {
        if (!handleShortcuts) {
            return@LaunchedEffect
        }
        container.shortcuts.events.collect { shortcut ->
            val envelope = envelopeAt(cursor) ?: return@collect
            when (shortcut) {
                Shortcut.TOGGLE_READ -> viewModel.setFlag(setOf(envelope.id), "\\Seen", !envelope.isSeen)
                Shortcut.TOGGLE_FLAG -> viewModel.setFlag(setOf(envelope.id), "\\Flagged", !envelope.isFlagged)
                else -> Unit
            }
        }
    }
    LaunchedEffect(listState, state.filter) {
        snapshotFlow {
            val info = listState.layoutInfo
            info.visibleItemsInfo.firstOrNull()?.index to
                (info.visibleItemsInfo.lastOrNull()?.index ?: 0)
        }.distinctUntilChanged()
            .collect { (first, last) ->
                if (first != null) {
                    if (state.filter == MessageFilter.ALL) {
                        viewModel.onVisibleRange(first, last)
                    } else if (last >= state.filteredRows.size - FILTER_LOAD_MARGIN) {
                        viewModel.requestMoreForFilter()
                    }
                }
            }
    }

    // Set-of-UIDs pending a Trash purge confirmation; null = no dialog.
    var pendingPurge by remember { mutableStateOf<Set<Long>?>(null) }

    // Set-of-UIDs awaiting a move destination; null = sheet closed.
    var moveRequest by remember { mutableStateOf<Set<Long>?>(null) }

    // UID whose long-press context menu is open.
    var menuUid by remember { mutableStateOf<Long?>(null) }

    val disposeOrConfirm: (Set<Long>) -> Unit = { uids ->
        if (viewModel.isTrashFolder) {
            pendingPurge = uids
        } else {
            viewModel.dispose(uids)
        }
    }

    Scaffold(
        modifier =
            modifier
                .fillMaxSize()
                .focusRequester(focusRequester)
                .focusable()
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown || event.isCtrlPressed) {
                        return@onPreviewKeyEvent false
                    }
                    when (event.key) {
                        Key.J, Key.DirectionDown -> {
                            moveCursor(1)
                            true
                        }
                        Key.K, Key.DirectionUp -> {
                            moveCursor(-1)
                            true
                        }
                        Key.Enter, Key.NumPadEnter -> {
                            envelopeAt(cursor)?.let(onOpenMessage) != null
                        }
                        else -> false
                    }
                },
        floatingActionButton = {
            if (!state.selecting) {
                FloatingActionButton(onClick = onCompose) {
                    Icon(Icons.Default.Create, contentDescription = stringResource(R.string.compose_new))
                }
            }
        },
        topBar = {
            if (state.selecting) {
                SelectionTopBar(
                    state = state,
                    viewModel = viewModel,
                    onDispose = { disposeOrConfirm(state.selected) },
                    onMove = {
                        viewModel.loadFolderChoices()
                        moveRequest = state.selected
                    },
                )
            } else {
                DefaultTopBar(
                    folder = folder,
                    state = state,
                    viewModel = viewModel,
                    onOpenSearch = onOpenSearch,
                    onBack = onBack,
                )
            }
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            FilterPills(state = state, onFilter = viewModel::setFilter)
            PullToRefreshBox(
                isRefreshing = state.refreshing,
                onRefresh = viewModel::refresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
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
                    if (state.filter == MessageFilter.ALL) {
                        // Loaded rows are keyed by UID so per-row state (the
                        // swipe offset especially) travels with the message:
                        // an optimistic removal shifts the window down while
                        // the swiped row is still displaced, and an
                        // index-keyed slot would hand that displacement to
                        // whichever message moves up into it. Placeholders
                        // key by slot (negative, so no UID collision).
                        items(state.total ?: 0, key = { state.envelopes[it]?.id ?: -(it + 1L) }) { index ->
                            val envelope = state.envelopes[index]
                            if (envelope == null) {
                                // No animateRowRemoval here: placeholder keys
                                // are positional, so they never move — and
                                // fading one out on the placeholder-to-loaded
                                // key swap would ghost "• • •" over the row.
                                PlaceholderRow()
                                HorizontalDivider()
                            } else {
                                Column(modifier = Modifier.animateRowRemoval(this)) {
                                    InteractiveRow(
                                        envelope = envelope,
                                        state = state,
                                        viewModel = viewModel,
                                        bimiLookup = bimiLookup,
                                        mailDomains = mailDomains,
                                        highlighted = index == cursor || envelope.id == highlightedUid,
                                        menuOpen = menuUid == envelope.id,
                                        onMenuChange = { open -> menuUid = if (open) envelope.id else null },
                                        onOpen = { onOpenMessage(envelope) },
                                        onDispose = { disposeOrConfirm(setOf(envelope.id)) },
                                        onMove = {
                                            viewModel.loadFolderChoices()
                                            moveRequest = setOf(envelope.id)
                                        },
                                    )
                                    HorizontalDivider()
                                }
                            }
                        }
                    } else {
                        itemsIndexed(state.filteredRows, key = { _, it -> it.id }) { index, envelope ->
                            Column(modifier = Modifier.animateRowRemoval(this)) {
                                InteractiveRow(
                                    envelope = envelope,
                                    state = state,
                                    viewModel = viewModel,
                                    bimiLookup = bimiLookup,
                                    mailDomains = mailDomains,
                                    highlighted = index == cursor || envelope.id == highlightedUid,
                                    menuOpen = menuUid == envelope.id,
                                    onMenuChange = { open -> menuUid = if (open) envelope.id else null },
                                    onOpen = { onOpenMessage(envelope) },
                                    onDispose = { disposeOrConfirm(setOf(envelope.id)) },
                                    onMove = {
                                        viewModel.loadFolderChoices()
                                        moveRequest = setOf(envelope.id)
                                    },
                                )
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    pendingPurge?.let { uids ->
        PurgeConfirmDialog(
            count = uids.size,
            onConfirm = {
                viewModel.dispose(uids)
                pendingPurge = null
            },
            onDismiss = { pendingPurge = null },
        )
    }

    moveRequest?.let { uids ->
        MoveSheet(
            choices = state.folderChoices,
            onPick = { destination ->
                viewModel.move(uids, destination)
                moveRequest = null
            },
            onDismiss = { moveRequest = null },
        )
    }
}

private const val FILTER_LOAD_MARGIN = 10

// ------------------------------------------------------------------ top bars

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DefaultTopBar(
    folder: String,
    state: MessageListUiState,
    viewModel: MessageListViewModel,
    onOpenSearch: () -> Unit,
    onBack: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text(folder) },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.back),
                )
            }
        },
        actions = {
            IconButton(onClick = onOpenSearch) {
                Icon(Icons.Default.Search, contentDescription = stringResource(R.string.search))
            }
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more_actions))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.select_messages)) },
                    onClick = {
                        menuOpen = false
                        viewModel.startSelecting()
                    },
                )
                HorizontalDivider()
                MessageSortField.entries.forEach { field ->
                    DropdownMenuItem(
                        text = { Text(stringResource(field.labelRes())) },
                        trailingIcon = { if (state.sortField == field) ActiveMark() },
                        onClick = {
                            menuOpen = false
                            viewModel.setSort(field, state.sortDescending)
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sort_descending)) },
                    trailingIcon = { if (state.sortDescending) ActiveMark() },
                    onClick = {
                        menuOpen = false
                        viewModel.setSort(state.sortField, !state.sortDescending)
                    },
                )
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SelectionTopBar(
    state: MessageListUiState,
    viewModel: MessageListViewModel,
    onDispose: () -> Unit,
    onMove: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = {
            Text(
                pluralStringResource(R.plurals.selected_count, state.selected.size, state.selected.size),
            )
        },
        navigationIcon = {
            IconButton(onClick = viewModel::stopSelecting) {
                Icon(Icons.Default.Close, contentDescription = stringResource(R.string.done_selecting))
            }
        },
        actions = {
            IconButton(
                onClick = { viewModel.setFlag(state.selected, "\\Seen", true) },
                enabled = state.selected.isNotEmpty(),
            ) {
                Icon(Icons.Default.MailOutline, contentDescription = stringResource(R.string.mark_read))
            }
            IconButton(
                onClick = { viewModel.setFlag(state.selected, "\\Flagged", true) },
                enabled = state.selected.isNotEmpty(),
            ) {
                Icon(Icons.Default.Star, contentDescription = stringResource(R.string.add_flag))
            }
            IconButton(
                onClick = onDispose,
                enabled = state.selected.isNotEmpty(),
            ) {
                Icon(
                    disposeIconPainter(viewModel.isTrashFolder),
                    contentDescription =
                        stringResource(
                            disposeLabelRes(viewModel.isTrashFolder),
                        ),
                )
            }
            IconButton(onClick = { menuOpen = true }, enabled = state.selected.isNotEmpty()) {
                Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more_actions))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.mark_unread)) },
                    onClick = {
                        menuOpen = false
                        viewModel.setFlag(state.selected, "\\Seen", false)
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.remove_flag)) },
                    onClick = {
                        menuOpen = false
                        viewModel.setFlag(state.selected, "\\Flagged", false)
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.move_to)) },
                    onClick = {
                        menuOpen = false
                        onMove()
                    },
                )
            }
        },
    )
}

@Composable
private fun ActiveMark() {
    Icon(Icons.Default.Check, contentDescription = stringResource(R.string.active_option))
}

private fun MessageSortField.labelRes(): Int =
    when (this) {
        MessageSortField.DATE_RECEIVED -> R.string.sort_date_received
        MessageSortField.DATE_SENT -> R.string.sort_date_sent
        MessageSortField.FROM -> R.string.sort_from
        MessageSortField.SUBJECT -> R.string.sort_subject
    }

// --------------------------------------------------------------- filter row

@Composable
private fun FilterPills(
    state: MessageListUiState,
    onFilter: (MessageFilter) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        MessageFilter.entries.forEach { filter ->
            val count =
                when (filter) {
                    MessageFilter.ALL -> state.counts?.all
                    MessageFilter.UNREAD -> state.counts?.unseen
                    MessageFilter.FLAGGED -> state.counts?.flagged
                }
            val label = stringResource(filter.labelRes())
            FilterChip(
                selected = state.filter == filter,
                onClick = { onFilter(filter) },
                label = { Text(if (count != null) "$label $count" else label) },
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

private fun MessageFilter.labelRes(): Int =
    when (this) {
        MessageFilter.ALL -> R.string.filter_all
        MessageFilter.UNREAD -> R.string.filter_unread
        MessageFilter.FLAGGED -> R.string.filter_flagged
    }

// --------------------------------------------------------------------- rows

@Composable
private fun PlaceholderRow(modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth().padding(16.dp)) {
        Text(
            text = "• • •",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

/**
 * A loaded row with the full interaction surface: tap to open (or toggle
 * selection), long-press context menu, and swipe actions when not
 * selecting.
 */
@Composable
private fun InteractiveRow(
    envelope: Envelope,
    state: MessageListUiState,
    viewModel: MessageListViewModel,
    bimiLookup: suspend (String) -> String?,
    mailDomains: List<String>,
    highlighted: Boolean,
    menuOpen: Boolean,
    onMenuChange: (Boolean) -> Unit,
    onOpen: () -> Unit,
    onDispose: () -> Unit,
    onMove: () -> Unit,
) {
    // A keyboard-cursor or open-in-pane row gets a primary state layer over
    // the surface, composited here so the swipe backing stays opaque.
    val rowColor =
        if (highlighted) {
            MaterialTheme.colorScheme.primary
                .copy(alpha = 0.12f)
                .compositeOver(MaterialTheme.colorScheme.surface)
        } else {
            MaterialTheme.colorScheme.surface
        }
    Box(modifier = Modifier.background(rowColor)) {
        if (state.selecting) {
            EnvelopeRow(
                envelope = envelope,
                onClick = { viewModel.toggleSelected(envelope.id) },
                checked = envelope.id in state.selected,
                bimiLookup = bimiLookup,
                mailDomains = mailDomains,
            )
        } else {
            SwipeRow(
                isSeen = envelope.isSeen,
                onToggleSeen = { viewModel.setFlag(setOf(envelope.id), "\\Seen", !envelope.isSeen) },
                onDispose = onDispose,
                isTrashFolder = viewModel.isTrashFolder,
                containerColor = rowColor,
            ) {
                EnvelopeRow(
                    envelope = envelope,
                    onClick = onOpen,
                    onLongClick = { onMenuChange(true) },
                    bimiLookup = bimiLookup,
                    mailDomains = mailDomains,
                )
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { onMenuChange(false) }) {
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(
                            if (envelope.isSeen) R.string.mark_unread else R.string.mark_read,
                        ),
                    )
                },
                onClick = {
                    onMenuChange(false)
                    viewModel.setFlag(setOf(envelope.id), "\\Seen", !envelope.isSeen)
                },
            )
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(
                            if (envelope.isFlagged) R.string.remove_flag else R.string.add_flag,
                        ),
                    )
                },
                onClick = {
                    onMenuChange(false)
                    viewModel.setFlag(setOf(envelope.id), "\\Flagged", !envelope.isFlagged)
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.move_to)) },
                onClick = {
                    onMenuChange(false)
                    onMove()
                },
            )
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(
                            disposeLabelRes(viewModel.isTrashFolder),
                        ),
                    )
                },
                onClick = {
                    onMenuChange(false)
                    onDispose()
                },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.select_messages)) },
                onClick = {
                    onMenuChange(false)
                    viewModel.startSelecting()
                    viewModel.toggleSelected(envelope.id)
                },
            )
        }
    }
}

// ------------------------------------------------------------------ dialogs

@Composable
internal fun PurgeConfirmDialog(
    count: Int,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.purge_confirm_title)) },
        text = { Text(pluralStringResource(R.plurals.purge_confirm_body, count, count)) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.purge), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MoveSheet(
    choices: List<String>?,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        if (choices == null) {
            CircularProgressIndicator(modifier = Modifier.padding(24.dp))
        } else {
            LazyColumn {
                item {
                    Text(
                        text = stringResource(R.string.move_to),
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
                items(choices.size, key = { choices[it] }) { index ->
                    val destination = choices[index]
                    ListItem(
                        headlineContent = { Text(destination) },
                        modifier = Modifier.fillMaxWidth().clickable { onPick(destination) },
                    )
                }
            }
        }
    }
}
