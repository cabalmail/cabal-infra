package com.cabalmail.android.ui.mail

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.cabalmail.android.R

/**
 * A link the reader is willing to offer actions for, mirroring the Apple
 * clients' `LinkMenuTarget`: executable and local schemes never get a menu,
 * so a crafted message can't use the reader as a launcher for them.
 */
internal data class LinkMenuTarget(
    val url: String,
    val scheme: String,
) {
    /** Picks the open row's label: "Open in browser" vs the generic "Open link". */
    val isWebLink: Boolean
        get() = scheme == "http" || scheme == "https"

    companion object {
        /**
         * Schemes that are silently swallowed. The Apple list plus the
         * Android-specific `intent:`/`content:` vectors.
         */
        private val BLOCKED_SCHEMES =
            setOf("javascript", "vbscript", "data", "blob", "file", "about", "intent", "content")

        /** RFC 3986 scheme; anything scheme-less (a relative href) has no useful target. */
        private val SCHEME = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*(?=:)")

        fun from(url: String?): LinkMenuTarget? {
            val trimmed = url?.trim().orEmpty()
            val scheme = SCHEME.find(trimmed)?.value?.lowercase() ?: return null
            if (scheme in BLOCKED_SCHEMES) {
                return null
            }
            return LinkMenuTarget(url = trimmed, scheme = scheme)
        }
    }
}

/**
 * Actions for a tapped body link (plan parity with the Apple clients' link
 * popover): the full destination up top so it can be vetted, then copy,
 * open, and share. "Copy link text" has no Android counterpart — with
 * JavaScript off the tap only carries the URL, which matches the Apple
 * menu's empty-text case where that row is hidden.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LinkMenuSheet(
    target: LinkMenuTarget,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(modifier = Modifier.padding(bottom = 16.dp)) {
            SelectionContainer {
                Text(
                    text = target.url,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            HorizontalDivider()
            ListItem(
                headlineContent = { Text(stringResource(R.string.link_menu_copy)) },
                modifier =
                    Modifier.fillMaxWidth().clickable {
                        context
                            .getSystemService(ClipboardManager::class.java)
                            ?.setPrimaryClip(ClipData.newPlainText(target.url, target.url))
                        onDismiss()
                    },
            )
            ListItem(
                headlineContent = {
                    Text(
                        stringResource(
                            if (target.isWebLink) R.string.link_menu_open_web else R.string.link_menu_open,
                        ),
                    )
                },
                modifier =
                    Modifier.fillMaxWidth().clickable {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, target.url.toUri())) }
                        onDismiss()
                    },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.link_menu_share)) },
                modifier =
                    Modifier.fillMaxWidth().clickable {
                        val send =
                            Intent(Intent.ACTION_SEND)
                                .setType("text/plain")
                                .putExtra(Intent.EXTRA_TEXT, target.url)
                        runCatching { context.startActivity(Intent.createChooser(send, null)) }
                        onDismiss()
                    },
            )
        }
    }
}
