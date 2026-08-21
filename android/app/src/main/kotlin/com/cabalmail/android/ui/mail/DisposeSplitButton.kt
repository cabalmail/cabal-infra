package com.cabalmail.android.ui.mail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.DisposeAdvance

/**
 * The reader's dispose control, mirroring the Apple clients' split button:
 * tap runs the preferred dispose, long-press opens the action × advance
 * menu (Apple's touch rendering of `Menu`/`primaryAction`). Picking a row
 * makes that pair the new preference and disposes immediately. The icon and
 * label follow the resolved [DisposeIntent], not the raw preference, so
 * archive shows a box, restore an up-arrow box, and only Trash-bound
 * actions read as destructive.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DisposeSplitButton(
    folder: String,
    preferredAction: DisposeAction,
    preferredAdvance: DisposeAdvance,
    enabled: Boolean,
    /** Null action = the primary tap (follow the preference as-is). */
    onDispose: (action: DisposeAction?, advance: DisposeAdvance) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val intent = DisposeIntent.standard(preferredAction, folder)
    Box {
        Box(
            modifier =
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .combinedClickable(
                        enabled = enabled,
                        onClick = { onDispose(null, preferredAdvance) },
                        onLongClickLabel = stringResource(R.string.dispose_options),
                        onLongClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            menuOpen = true
                        },
                    ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = disposeIcon(intent),
                contentDescription = stringResource(disposeVerbRes(intent)),
                tint =
                    when {
                        !enabled -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                        intent.isDestructive -> MaterialTheme.colorScheme.error
                        else -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DisposeAction.entries.forEachIndexed { index, action ->
                if (index > 0) {
                    HorizontalDivider()
                }
                val verb = stringResource(disposeVerbRes(DisposeIntent.explicit(action, folder)))
                DisposeAdvance.entries.forEach { advance ->
                    val selected = preferredAction == action && preferredAdvance == advance
                    DropdownMenuItem(
                        text = {
                            Text(
                                stringResource(
                                    R.string.dispose_then,
                                    verb,
                                    stringResource(advanceLabelRes(advance)).lowercase(),
                                ),
                            )
                        },
                        trailingIcon =
                            if (selected) {
                                { Icon(Icons.Default.Check, contentDescription = null) }
                            } else {
                                null
                            },
                        onClick = {
                            menuOpen = false
                            onDispose(action, advance)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun disposeIcon(intent: DisposeIntent): Painter =
    when (intent) {
        DisposeIntent.Purge -> rememberVectorPainter(Icons.Default.Delete)
        DisposeIntent.Restore -> painterResource(R.drawable.ic_unarchive)
        is DisposeIntent.Move ->
            when (intent.action) {
                DisposeAction.ARCHIVE -> painterResource(R.drawable.ic_archive)
                DisposeAction.TRASH -> rememberVectorPainter(Icons.Default.Delete)
            }
    }

internal fun disposeVerbRes(intent: DisposeIntent): Int =
    when (intent) {
        DisposeIntent.Purge -> R.string.purge
        DisposeIntent.Restore -> R.string.restore
        is DisposeIntent.Move ->
            when (intent.action) {
                DisposeAction.ARCHIVE -> R.string.archive
                DisposeAction.TRASH -> R.string.dispose_to_trash
            }
    }

internal fun advanceLabelRes(advance: DisposeAdvance): Int =
    when (advance) {
        DisposeAdvance.NEXT -> R.string.opt_advance_next
        DisposeAdvance.NEXT_UNREAD -> R.string.opt_advance_next_unread
        DisposeAdvance.PREVIOUS_UNREAD -> R.string.opt_advance_previous_unread
        DisposeAdvance.FIRST_UNREAD -> R.string.opt_advance_first_unread
    }
