package com.cabalmail.android.ui.mail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.LocalRowPadding
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.hasAuthFailure
import com.cabalmail.kit.models.mailboxAddress
import com.cabalmail.kit.models.mailboxDisplayName
import com.cabalmail.kit.models.sentInstant
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * One message row, shared by the folder window and search results.
 * [checked] non-null renders the selection-mode checkbox; [folderLabel]
 * names the source folder on cross-folder search results; [bimiLookup]
 * resolves a sender domain to a BIMI logo URL (initials render meanwhile).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun EnvelopeRow(
    envelope: Envelope,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    checked: Boolean? = null,
    folderLabel: String? = null,
    bimiLookup: (suspend (String) -> String?)? = null,
) {
    val emphasis = if (envelope.isSeen) FontWeight.Normal else FontWeight.Bold
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
            modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                .padding(horizontal = 16.dp, vertical = LocalRowPadding.current),
    ) {
        if (checked != null) {
            Checkbox(checked = checked, onCheckedChange = { onClick() })
            Spacer(Modifier.width(4.dp))
        }
        SenderAvatar(
            mailbox = envelope.from.firstOrNull(),
            bimiLookup = bimiLookup,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = envelope.from.firstOrNull()?.let(::mailboxDisplayName) ?: "(unknown sender)",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = emphasis,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (envelope.isHighPriority) {
                    Text(
                        text = "!",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.error,
                    )
                    Spacer(Modifier.width(4.dp))
                }
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
            folderLabel?.let { label ->
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}

/**
 * Colored-initial disc with the sender's BIMI logo drawn over it once (and
 * if) the lookup lands. The disc hue derives from the sender address so a
 * given correspondent keeps a stable color.
 */
@Composable
fun SenderAvatar(
    mailbox: String?,
    bimiLookup: (suspend (String) -> String?)?,
    modifier: Modifier = Modifier,
) {
    val address = mailbox?.let(::mailboxAddress)
    val domain = address?.substringAfterLast('@', missingDelimiterValue = "")?.ifEmpty { null }
    val initial =
        mailbox
            ?.let(::mailboxDisplayName)
            ?.firstOrNull { it.isLetterOrDigit() }
            ?.uppercaseChar()
            ?.toString() ?: "?"
    val hue = ((address ?: "?").hashCode().mod(360)).toFloat()
    val logoUrl by
        produceState<String?>(initialValue = null, domain, bimiLookup) {
            value =
                if (domain != null && bimiLookup != null) {
                    bimiLookup(domain)
                } else {
                    null
                }
        }
    Box(
        contentAlignment = Alignment.Center,
        modifier =
            modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(Color.hsv(hue, 0.35f, 0.55f)),
    ) {
        Text(
            text = initial,
            style = MaterialTheme.typography.titleMedium,
            color = Color.White,
        )
        logoUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                modifier = Modifier.size(40.dp).clip(CircleShape),
            )
        }
    }
}

internal fun shortDate(instant: Instant): String =
    DateTimeFormatter
        .ofPattern("MMM d")
        .withZone(ZoneId.systemDefault())
        .format(instant)

/**
 * Swipe surface per the plan: start-to-end toggles read, end-to-start
 * disposes (archive, or purge-with-confirmation in Trash). Both actions
 * settle the row back rather than dismissing it — a successful dispose
 * removes the row from its list instead.
 */
@Composable
internal fun SwipeRow(
    isSeen: Boolean,
    onToggleSeen: () -> Unit,
    onDispose: () -> Unit,
    content: @Composable () -> Unit,
) {
    val currentToggleSeen by rememberUpdatedState(onToggleSeen)
    val currentDispose by rememberUpdatedState(onDispose)
    val swipeState =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                when (value) {
                    SwipeToDismissBoxValue.StartToEnd -> currentToggleSeen()
                    SwipeToDismissBoxValue.EndToStart -> currentDispose()
                    SwipeToDismissBoxValue.Settled -> Unit
                }
                false
            },
        )
    SwipeToDismissBox(
        state = swipeState,
        backgroundContent = {
            val (color, icon, alignment) =
                when (swipeState.dismissDirection) {
                    SwipeToDismissBoxValue.StartToEnd ->
                        Triple(
                            MaterialTheme.colorScheme.secondaryContainer,
                            Icons.Default.Email,
                            Alignment.CenterStart,
                        )
                    else ->
                        Triple(
                            MaterialTheme.colorScheme.errorContainer,
                            Icons.Default.Delete,
                            Alignment.CenterEnd,
                        )
                }
            Box(
                contentAlignment = alignment,
                modifier = Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp),
            ) {
                Icon(
                    icon,
                    contentDescription =
                        stringResource(
                            if (swipeState.dismissDirection == SwipeToDismissBoxValue.StartToEnd) {
                                if (isSeen) R.string.mark_unread else R.string.mark_read
                            } else {
                                R.string.archive
                            },
                        ),
                )
            }
        },
    ) {
        Box(modifier = Modifier.background(MaterialTheme.colorScheme.surface)) {
            content()
        }
    }
}
