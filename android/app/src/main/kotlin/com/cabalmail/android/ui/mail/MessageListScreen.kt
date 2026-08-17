package com.cabalmail.android.ui.mail

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.hasAuthFailure
import com.cabalmail.kit.models.mailboxDisplayName
import com.cabalmail.kit.models.sentInstant
import kotlinx.coroutines.flow.distinctUntilChanged
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageListScreen(
    folder: String,
    state: MessageListUiState,
    onRefresh: () -> Unit,
    onVisibleRange: (Int, Int) -> Unit,
    onOpenMessage: (Envelope) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            info.visibleItemsInfo.firstOrNull()?.index to
                (info.visibleItemsInfo.lastOrNull()?.index ?: 0)
        }.distinctUntilChanged()
            .collect { (first, last) ->
                if (first != null) {
                    onVisibleRange(first, last)
                }
            }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
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
            )
        },
    ) { innerPadding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = onRefresh,
            modifier = Modifier.padding(innerPadding).fillMaxSize(),
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
                val total = state.total ?: 0
                items(total, key = { it }) { index ->
                    val envelope = state.envelopes[index]
                    if (envelope == null) {
                        PlaceholderRow()
                    } else {
                        EnvelopeRow(
                            envelope = envelope,
                            onClick = { onOpenMessage(envelope) },
                        )
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

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

@Composable
private fun EnvelopeRow(
    envelope: Envelope,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val emphasis = if (envelope.isSeen) FontWeight.Normal else FontWeight.Bold
    Column(
        modifier =
            modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = envelope.from.firstOrNull()?.let(::mailboxDisplayName) ?: "(unknown sender)",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = emphasis,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (envelope.hasAuthFailure) {
                Icon(
                    Icons.Default.Warning,
                    contentDescription = stringResource(R.string.auth_warning),
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
            }
            if (envelope.isFlagged) {
                Icon(
                    Icons.Default.Star,
                    contentDescription = stringResource(R.string.flagged),
                    tint = MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
            }
            Text(
                text = envelope.sentInstant()?.let(::shortDate) ?: "",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = envelope.subject.ifEmpty { stringResource(R.string.no_subject) },
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = emphasis,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (envelope.hasAttachments) {
                Text(
                    text = "📎",
                    style = MaterialTheme.typography.labelSmall,
                )
            }
        }
    }
}

private fun shortDate(instant: Instant): String =
    DateTimeFormatter
        .ofPattern("MMM d")
        .withZone(ZoneId.systemDefault())
        .format(instant)
