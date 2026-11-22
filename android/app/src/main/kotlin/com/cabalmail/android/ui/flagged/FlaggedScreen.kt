package com.cabalmail.android.ui.flagged

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Email
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.feeds.FeedItemRow
import com.cabalmail.android.ui.feeds.FeedItemRowMenu
import com.cabalmail.android.ui.feeds.FeedSwipeRow
import com.cabalmail.android.ui.mail.CrossFolderMailRow
import com.cabalmail.android.ui.mail.PurgeConfirmDialog
import com.cabalmail.android.ui.mail.SearchScope
import com.cabalmail.android.ui.mail.animateRowRemoval
import com.cabalmail.android.ui.mail.searchScope
import com.cabalmail.android.ui.mail.searchScopePhrase
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.android.ui.theme.FlagToggle
import com.cabalmail.android.ui.theme.LocalFlagPalette
import com.cabalmail.android.ui.theme.text
import com.cabalmail.kit.flagged.FlaggedRow
import com.cabalmail.kit.flagged.FlaggedSource
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The Flagged view (`docs/1.x/cross-media-ux-plan.md`, Phase 5): flagged
 * messages and flagged feed items in one list by date, each row under its
 * medium's glyph and opening in its medium's own reader. A message's row
 * is the one Search draws, with its swipes; a feed item's is the feed
 * list's, with its swipes and its menu.
 *
 * Above the rows: the flag pill, once Settings > Flags holds a flag of
 * the user's own; a line when flagged mail could not be had ([online]
 * chooses its words); a line when the server stopped at its cap; and the
 * folders the mail came from, since unsubscribed folders and Trash are
 * not searched.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlaggedScreen(
    state: FlaggedUiState,
    viewModel: FlaggedViewModel,
    online: Boolean,
    bimiLookup: suspend (String) -> String?,
    /** Deployment mail domains, for a message row's delivered-to address. */
    mailDomains: List<String>,
    onOpenMessage: (Envelope) -> Unit,
    onOpenItem: (RssItem) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    /** The key of the row open in a pane beside the list ([com.cabalmail.kit.models.ItemRef.key]), if any. */
    highlightedKey: String? = null,
) {
    val palette = LocalFlagPalette.current
    var pendingPurge by remember { mutableStateOf<Envelope?>(null) }
    // Back online with nothing to show for mail: ask again without a tap.
    LaunchedEffect(online) {
        if (online && state.mailFailure != null) viewModel.retryMail()
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.flagged_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            if (FlaggedPicker.isShown(palette, state.criterion)) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                    FlaggedPickPill(
                        palette = palette,
                        criterion = state.criterion,
                        onPick = viewModel::pick,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
            }
            PullToRefreshBox(
                isRefreshing = state.refreshing,
                onRefresh = viewModel::refresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                FlaggedRows(
                    state = state,
                    viewModel = viewModel,
                    online = online,
                    palette = palette,
                    bimiLookup = bimiLookup,
                    mailDomains = mailDomains,
                    onOpenMessage = onOpenMessage,
                    onOpenItem = onOpenItem,
                    onConfirmPurge = { pendingPurge = it },
                    highlightedKey = highlightedKey,
                )
            }
        }
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

@Composable
private fun FlaggedRows(
    state: FlaggedUiState,
    viewModel: FlaggedViewModel,
    online: Boolean,
    palette: List<FlagPaletteEntry>,
    bimiLookup: suspend (String) -> String?,
    mailDomains: List<String>,
    onOpenMessage: (Envelope) -> Unit,
    onOpenItem: (RssItem) -> Unit,
    onConfirmPurge: (Envelope) -> Unit,
    highlightedKey: String?,
) {
    val listState = rememberLazyListState()
    // A list that begins afresh (the open, a pick) opens at the top: left
    // alone, Compose would follow the old first row's key to wherever it
    // sorts in the new list, or sit on the footer that was alone on screen.
    val anchor = remember { intArrayOf(state.listEpoch) }
    SideEffect {
        if (state.listEpoch != anchor[0]) listState.requestScrollToItem(0)
        anchor[0] = state.listEpoch
    }
    val page = state.page
    val notice = mailNotice(state, online)
    val scope = searchScope(state.foldersSearched, folderOnly = false, anchorFolder = null) as? SearchScope.Folders

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
        state.error?.let { message ->
            item(key = "error") { NoticeLine(text = message, isError = true) }
        }
        notice?.let { text ->
            item(key = "mail-notice") {
                NoticeLine(
                    text = text,
                    isError = false,
                    action = stringResource(R.string.retry).takeIf { !state.mailLoading },
                    onAction = viewModel::retryMail,
                )
            }
        }
        if (state.truncated) {
            item(key = "truncated") {
                NoticeLine(text = stringResource(R.string.flagged_mail_truncated), isError = false)
            }
        }
        if (scope != null && page.rows.isNotEmpty()) {
            item(key = "scope") {
                Text(
                    text = stringResource(R.string.flagged_scope, searchScopePhrase(scope)),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        if (state.isEmpty) {
            item(key = "empty") {
                Column(modifier = Modifier.fillMaxWidth().padding(24.dp)) {
                    Text(
                        FlaggedPicker.emptyTitle(palette, state.criterion).text(),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        stringResource(R.string.flagged_empty_body),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        items(page.rows, key = { it.ref.key }) { row ->
            Column(modifier = Modifier.animateRowRemoval(this)) {
                when (row) {
                    is FlaggedRow.Mail ->
                        MailRow(
                            envelope = row.envelope,
                            viewModel = viewModel,
                            bimiLookup = bimiLookup,
                            mailDomains = mailDomains,
                            onOpenMessage = onOpenMessage,
                            onConfirmPurge = onConfirmPurge,
                            highlighted = row.ref.key == highlightedKey,
                        )
                    is FlaggedRow.Feed ->
                        FeedRow(
                            item = row.item,
                            state = state,
                            viewModel = viewModel,
                            palette = palette,
                            onOpenItem = onOpenItem,
                            highlighted = row.ref.key == highlightedKey,
                        )
                }
                HorizontalDivider()
            }
        }
        if (state.mailLoading || page.next != null) {
            item(key = "more") {
                FlaggedFooter(state = state, onLoadMore = viewModel::loadMore, onRetry = viewModel::retryMail)
            }
        }
    }
}

/**
 * The line above the list when flagged mail could not be had. Offline it
 * says what the list is instead; online, where "needs a connection" would
 * be wrong, it says what the server said.
 */
@Composable
private fun mailNotice(
    state: FlaggedUiState,
    online: Boolean,
): String? =
    when (state.mailFailure) {
        null, FlaggedMailFailure.NEXT_PAGE -> null
        FlaggedMailFailure.NEVER_LOADED ->
            if (online) state.mailFailureMessage else stringResource(R.string.flagged_mail_offline)
        FlaggedMailFailure.REFRESH -> stringResource(R.string.flagged_mail_stale)
    }

/**
 * The end of the list while there is more: the first page loading, the
 * sentinel whose appearance asks for the next one, or the next page's
 * failure with a way to try it again.
 */
@Composable
private fun FlaggedFooter(
    state: FlaggedUiState,
    onLoadMore: () -> Unit,
    onRetry: () -> Unit,
) {
    val waitingOnMail = state.page.next == FlaggedSource.MAIL
    when {
        state.mailLoading ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(16.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), color = ColorTokens.accentForestFg())
                Text(
                    text =
                        stringResource(
                            if (state.mail.isEmpty()) R.string.flagged_loading else R.string.search_loading_more,
                        ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(start = 12.dp),
                )
            }
        waitingOnMail && state.mailFailure == FlaggedMailFailure.NEXT_PAGE ->
            NoticeLine(
                text = stringResource(R.string.flagged_mail_more_failed),
                isError = false,
                action = stringResource(R.string.retry),
                onAction = onRetry,
            )
        // A refresh that failed leaves the older load's horizon in place;
        // the line above the list carries the Retry.
        waitingOnMail && state.mailFailure != null -> Unit
        else -> {
            // Reaching this row pulls the next page; the keys change as
            // each one lands, so it asks again while it is still on screen.
            LaunchedEffect(state.mail.size, state.feed.size, state.mailCursor) { onLoadMore() }
            Text(
                text = stringResource(R.string.search_loading_more),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.padding(16.dp),
            )
        }
    }
}

@Composable
private fun NoticeLine(
    text: String,
    isError: Boolean,
    action: String? = null,
    onAction: () -> Unit = {},
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
    ) {
        Text(
            text = text,
            color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
        if (action != null) {
            TextButton(onClick = onAction) { Text(action) }
        }
    }
}

/**
 * A row under its medium's glyph, in a gutter of its own so neither
 * medium's row is redrawn to make room. The gutter takes the open row's
 * tint with the row, so the tint runs edge to edge.
 */
@Composable
private fun MediumGutter(
    glyph: Painter,
    description: String,
    highlighted: Boolean,
    content: @Composable () -> Unit,
) {
    val rowColor =
        if (highlighted) {
            MaterialTheme.colorScheme.primary
                .copy(alpha = 0.12f)
                .compositeOver(MaterialTheme.colorScheme.surface)
        } else {
            MaterialTheme.colorScheme.surface
        }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.background(rowColor)) {
        Icon(
            glyph,
            contentDescription = description,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 12.dp).size(16.dp),
        )
        Box(modifier = Modifier.weight(1f)) { content() }
    }
}

@Composable
private fun MailRow(
    envelope: Envelope,
    viewModel: FlaggedViewModel,
    bimiLookup: suspend (String) -> String?,
    mailDomains: List<String>,
    onOpenMessage: (Envelope) -> Unit,
    onConfirmPurge: (Envelope) -> Unit,
    highlighted: Boolean,
) {
    val defaultFlag = FlagToggle.defaultFlag(LocalFlagPalette.current)
    MediumGutter(rememberVectorPainter(Icons.Default.Email), stringResource(R.string.flagged_row_mail), highlighted) {
        CrossFolderMailRow(
            envelope = envelope,
            bimiLookup = bimiLookup,
            mailDomains = mailDomains,
            onOpen = { onOpenMessage(envelope) },
            // As a search result's: the long press sets or clears the default flag.
            onLongClick = {
                viewModel.setMailFlag(envelope, defaultFlag.slot, !defaultFlag.isSetIn(envelope.flags))
            },
            onToggleSeen = { viewModel.toggleSeen(envelope) },
            onSetFlag = { slot, value -> viewModel.setMailFlag(envelope, slot, value) },
            onDispose = { viewModel.dispose(envelope) },
            onConfirmPurge = { onConfirmPurge(envelope) },
            highlighted = highlighted,
        )
    }
}

@Composable
private fun FeedRow(
    item: RssItem,
    state: FlaggedUiState,
    viewModel: FlaggedViewModel,
    palette: List<FlagPaletteEntry>,
    onOpenItem: (RssItem) -> Unit,
    highlighted: Boolean,
) {
    val flag = FlagToggle.defaultFlag(palette)
    val isFlagSet = item.carries(flag.slot)
    var menuOpen by remember(item.id) { mutableStateOf(false) }
    MediumGutter(painterResource(R.drawable.ic_rss_feed), stringResource(R.string.flagged_row_feed), highlighted) {
        FeedSwipeRow(
            isRead = item.isRead,
            flag = flag,
            isFlagSet = isFlagSet,
            onToggleRead = { viewModel.setRead(item, !item.isRead) },
            onToggleFlag = { viewModel.setFeedFlag(item, flag.slot, !isFlagSet) },
            highlighted = highlighted,
        ) {
            FeedItemRow(
                item = item,
                feedName = state.feedName(item),
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
            onSetFlag = { slot, isSet -> viewModel.setFeedFlag(item, slot, isSet) },
        )
    }
}

/**
 * The view's flag pill: lit while the view is narrowed to one flag, and a
 * tap opens the lists' menu of every flag and Any flag ([FlaggedPicker]).
 */
@Composable
private fun FlaggedPickPill(
    palette: List<FlagPaletteEntry>,
    criterion: FlagCriterion,
    onPick: (FlagCriterion) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        FilterChip(
            selected = FlaggedPicker.isNarrowed(criterion),
            onClick = { open = true },
            label = { Text(FlaggedPicker.label(palette, criterion).text()) },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            FlaggedPicker.rows(palette, criterion).forEach { row ->
                DropdownMenuItem(
                    text = { Text(row.label.text()) },
                    leadingIcon = {
                        when {
                            row.isChecked ->
                                Icon(Icons.Default.Check, contentDescription = stringResource(R.string.active_option))
                            row.color != null ->
                                Box(Modifier.size(10.dp).clip(CircleShape).background(ColorTokens.flag(row.color)))
                            else -> Box(Modifier.size(10.dp))
                        }
                    },
                    onClick = {
                        open = false
                        onPick(row.criterion)
                    },
                )
            }
        }
    }
}
