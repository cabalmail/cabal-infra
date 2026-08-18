package com.cabalmail.android.ui.mail

import android.content.ActivityNotFoundException
import android.content.Intent
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AssistChip
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import com.cabalmail.android.R
import com.cabalmail.kit.compose.ReplyBuilder
import com.cabalmail.kit.models.Attachment
import com.cabalmail.kit.models.AuthResults
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.mailboxDisplayName
import com.cabalmail.kit.models.readerModeHtml
import com.cabalmail.kit.models.sentInstant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageDetailScreen(
    state: MessageDetailUiState,
    viewModel: MessageDetailViewModel,
    bimiLookup: suspend (String) -> String?,
    onBack: () -> Unit,
    onCompose: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(state.departed) {
        if (state.departed) {
            onBack()
        }
    }
    LaunchedEffect(state.composeDraftId) {
        val draftId = state.composeDraftId ?: return@LaunchedEffect
        viewModel.consumeCompose()
        onCompose(draftId)
    }

    val context = LocalContext.current
    LaunchedEffect(state.openFile) {
        val (file, mime) = state.openFile ?: return@LaunchedEffect
        viewModel.consumeOpenFile()
        val uri =
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent =
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            viewModel.reportOpenFailure()
        }
    }

    var confirmingPurge by remember { mutableStateOf(false) }
    var showMoveSheet by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { viewModel.setFlag("\\Seen", state.envelope?.isSeen != true) },
                        enabled = !state.busy,
                    ) {
                        Icon(Icons.Default.Email, contentDescription = stringResource(R.string.toggle_read))
                    }
                    IconButton(
                        onClick = { viewModel.setFlag("\\Flagged", state.envelope?.isFlagged != true) },
                        enabled = !state.busy,
                    ) {
                        Icon(
                            Icons.Default.Star,
                            contentDescription = stringResource(R.string.flagged),
                            tint =
                                if (state.envelope?.isFlagged == true) {
                                    MaterialTheme.colorScheme.tertiary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                        )
                    }
                    IconButton(
                        onClick = {
                            if (viewModel.isTrashFolder) {
                                confirmingPurge = true
                            } else {
                                viewModel.dispose()
                            }
                        },
                        enabled = !state.busy,
                    ) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription =
                                stringResource(
                                    if (viewModel.isTrashFolder) R.string.purge else R.string.archive,
                                ),
                            tint =
                                if (viewModel.isTrashFolder) {
                                    MaterialTheme.colorScheme.error
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                        )
                    }
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more_actions))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.move_to)) },
                            onClick = {
                                menuOpen = false
                                viewModel.loadFolderChoices()
                                showMoveSheet = true
                            },
                        )
                        if (state.content?.bodyHtml?.isNotBlank() == true) {
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        stringResource(
                                            when (state.renderMode) {
                                                RenderMode.ORIGINAL -> R.string.render_reader
                                                RenderMode.READER -> R.string.render_original
                                            },
                                        ),
                                    )
                                },
                                onClick = {
                                    menuOpen = false
                                    viewModel.toggleRenderMode()
                                },
                            )
                        }
                    }
                },
            )
        },
        bottomBar = {
            ComposeActionsBar(
                isDraftsFolder = viewModel.isDraftsFolder,
                enabled = state.envelope != null && !state.busy && !state.seedingCompose,
                onReply = { viewModel.startReply(ReplyBuilder.Mode.REPLY) },
                onReplyAll = { viewModel.startReply(ReplyBuilder.Mode.REPLY_ALL) },
                onForward = { viewModel.startReply(ReplyBuilder.Mode.FORWARD) },
                onEditDraft = viewModel::editDraft,
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            state.envelope?.let { envelope ->
                MessageHeader(envelope = envelope, bimiLookup = bimiLookup)
                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
            }

            state.error?.let { message ->
                Text(
                    text = message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
            }
            if (state.busy && state.content == null) {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
            }

            if (state.attachments.isNotEmpty()) {
                AttachmentRow(
                    attachments = state.attachments,
                    downloading = state.downloading,
                    onOpen = viewModel::downloadAndOpen,
                )
            }

            val content = state.content
            if (content != null) {
                if (content.bodyHtml.isNotBlank()) {
                    if (!state.loadRemoteContent) {
                        TextButton(
                            onClick = viewModel::allowRemoteContent,
                            modifier = Modifier.padding(horizontal = 8.dp),
                        ) {
                            Text(stringResource(R.string.load_remote_content))
                        }
                    }
                    val html = state.resolvedHtml ?: content.bodyHtml
                    val darkMode = isSystemInDarkTheme()
                    HtmlBody(
                        html =
                            when (state.renderMode) {
                                RenderMode.ORIGINAL -> html
                                RenderMode.READER -> readerModeHtml(html, darkMode)
                            },
                        allowRemoteContent = state.loadRemoteContent,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    SelectionContainer(
                        modifier =
                            Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(16.dp),
                    ) {
                        Text(
                            text = content.bodyPlain,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }
    }

    if (confirmingPurge) {
        PurgeConfirmDialog(
            count = 1,
            onConfirm = {
                confirmingPurge = false
                viewModel.dispose()
            },
            onDismiss = { confirmingPurge = false },
        )
    }

    if (showMoveSheet) {
        MoveSheet(
            choices = state.folderChoices,
            onPick = { destination ->
                showMoveSheet = false
                viewModel.move(destination)
            },
            onDismiss = { showMoveSheet = false },
        )
    }
}

// -------------------------------------------------------------- compose bar

/**
 * Reply / reply-all / forward (plan §5.2), or Edit Draft in the Drafts
 * folder (plan §5.3). A bottom bar so the top bar's existing controls keep
 * their footprint.
 */
@Composable
private fun ComposeActionsBar(
    isDraftsFolder: Boolean,
    enabled: Boolean,
    onReply: () -> Unit,
    onReplyAll: () -> Unit,
    onForward: () -> Unit,
    onEditDraft: () -> Unit,
) {
    BottomAppBar {
        if (isDraftsFolder) {
            TextButton(onClick = onEditDraft, enabled = enabled, modifier = Modifier.padding(horizontal = 8.dp)) {
                Icon(painterResource(R.drawable.ic_edit_note), contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.edit_draft))
            }
        } else {
            IconButton(onClick = onReply, enabled = enabled) {
                Icon(painterResource(R.drawable.ic_reply), contentDescription = stringResource(R.string.reply))
            }
            IconButton(onClick = onReplyAll, enabled = enabled) {
                Icon(painterResource(R.drawable.ic_reply_all), contentDescription = stringResource(R.string.reply_all))
            }
            IconButton(onClick = onForward, enabled = enabled) {
                Icon(painterResource(R.drawable.ic_forward), contentDescription = stringResource(R.string.forward))
            }
        }
    }
}

// ------------------------------------------------------------------- header

@Composable
private fun MessageHeader(
    envelope: Envelope,
    bimiLookup: suspend (String) -> String?,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row {
            SenderAvatar(mailbox = envelope.from.firstOrNull(), bimiLookup = bimiLookup)
            Spacer(Modifier.width(12.dp))
            Column {
                Text(
                    text = envelope.subject.ifEmpty { stringResource(R.string.no_subject) },
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = envelope.from.joinToString { mailboxDisplayName(it) },
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    text =
                        envelope.sentInstant()?.let {
                            DateTimeFormatter
                                .ofLocalizedDateTime(FormatStyle.MEDIUM)
                                .withZone(ZoneId.systemDefault())
                                .format(it)
                        } ?: "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
        if (envelope.to.isNotEmpty()) {
            Text(
                text = stringResource(R.string.header_to, envelope.to.joinToString { mailboxDisplayName(it) }),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        if (envelope.cc.isNotEmpty()) {
            Text(
                text = stringResource(R.string.header_cc, envelope.cc.joinToString { mailboxDisplayName(it) }),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        HeaderChips(envelope = envelope)
    }
}

/** SPF/DKIM/DMARC verdicts and the priority marker (plan §4.3). */
@Composable
private fun HeaderChips(envelope: Envelope) {
    val results: AuthResults? = envelope.authResults
    val chips =
        buildList {
            if (envelope.isHighPriority) {
                add(stringResource(R.string.priority_high) to true)
            }
            results?.spf?.let { add("SPF $it" to (it == "pass")) }
            results?.dkim?.let { add("DKIM $it" to (it == "pass")) }
            results?.dmarc?.let { add("DMARC $it" to (it == "pass")) }
        }
    if (chips.isEmpty()) {
        return
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(top = 6.dp),
    ) {
        chips.forEach { (label, ok) ->
            Surface(
                shape = MaterialTheme.shapes.small,
                color =
                    if (ok) {
                        MaterialTheme.colorScheme.secondaryContainer
                    } else {
                        MaterialTheme.colorScheme.errorContainer
                    },
            ) {
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
    }
}

// -------------------------------------------------------------- attachments

@Composable
private fun AttachmentRow(
    attachments: List<Attachment>,
    downloading: Set<Int>,
    onOpen: (Attachment) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        items(attachments, key = { it.id }) { attachment ->
            AssistChip(
                onClick = { onOpen(attachment) },
                label = {
                    Text(
                        text = attachment.name ?: stringResource(R.string.attachment_unnamed),
                        style = MaterialTheme.typography.labelMedium,
                    )
                },
                leadingIcon = {
                    if (attachment.id in downloading) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            modifier = Modifier.width(16.dp),
                        )
                    } else {
                        Text(text = "📎")
                    }
                },
            )
        }
    }
}

// --------------------------------------------------------------------- body

/**
 * Hardened HTML rendering, mirroring the plan's WKWebView-equivalent
 * posture: no JavaScript, remote loads blocked until the per-message
 * opt-in, all navigation swallowed.
 */
@Composable
private fun HtmlBody(
    html: String,
    allowRemoteContent: Boolean,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = false
                settings.blockNetworkLoads = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webViewClient =
                    object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean = true
                    }
            }
        },
        update = { webView ->
            webView.settings.blockNetworkLoads = !allowRemoteContent
            webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
        },
    )
}
