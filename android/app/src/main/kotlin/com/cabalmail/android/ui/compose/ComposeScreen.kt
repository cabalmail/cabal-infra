package com.cabalmail.android.ui.compose

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.cabalmail.android.R
import com.cabalmail.kit.models.Address
import com.cabalmail.kit.models.DraftAttachment

/**
 * The compose screen (plan §5.1). Full-screen on phone; the tablet
 * presentation arrives with the adaptive layout work in Phase 7.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposeScreen(
    state: ComposeUiState,
    viewModel: ComposeViewModel,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(state.dismissed) {
        if (state.dismissed) {
            onDismiss()
        }
    }
    BackHandler(enabled = !state.dismissed) { viewModel.requestClose() }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { viewModel.onStop() }

    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(state.error) {
        val message = state.error ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(message)
        viewModel.clearError()
    }

    var showNewAddress by remember { mutableStateOf(false) }
    var confirmingDiscard by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var attachMenuOpen by remember { mutableStateOf(false) }

    val photoPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris: List<Uri> ->
            viewModel.addAttachments(uris)
        }
    val filePicker =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
            viewModel.addAttachments(uris)
        }

    val toFocus = remember { FocusRequester() }
    // Saveable so a rotation does not re-focus (and pop the keyboard).
    var focusedOnce by rememberSaveable { mutableStateOf(false) }
    val draftLoaded = state.draft.updatedAt != 0L
    LaunchedEffect(draftLoaded) {
        // Initial focus once the draft has loaded: To for a fresh compose.
        // Replies leave focus alone — focusing the (tall) body scrolls the
        // From row off the top, and the From default is the thing to check.
        if (focusedOnce || !draftLoaded) {
            return@LaunchedEffect
        }
        focusedOnce = true
        if (state.draft.to.isEmpty()) {
            runCatching { toFocus.requestFocus() }
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize().imePadding(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(
                            when (ComposeTitle.forSession(state.draft.composeIntent, state.resumedFromServer)) {
                                ComposeTitleKind.NEW -> R.string.compose_title_new
                                ComposeTitleKind.REPLY -> R.string.compose_title_reply
                                ComposeTitleKind.FORWARD -> R.string.compose_title_forward
                                ComposeTitleKind.DRAFT -> R.string.compose_title_draft
                            },
                        ),
                    )
                },
                navigationIcon = {
                    IconButton(onClick = viewModel::requestClose, enabled = !state.sending) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.compose_close))
                    }
                },
                actions = {
                    IconButton(onClick = { attachMenuOpen = true }, enabled = !state.sending) {
                        Icon(
                            painterResource(R.drawable.ic_attach_file),
                            contentDescription = stringResource(R.string.compose_attach),
                        )
                    }
                    DropdownMenu(expanded = attachMenuOpen, onDismissRequest = { attachMenuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.compose_attach_photos)) },
                            onClick = {
                                attachMenuOpen = false
                                photoPicker.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
                                )
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.compose_attach_files)) },
                            onClick = {
                                attachMenuOpen = false
                                filePicker.launch(arrayOf("*/*"))
                            },
                        )
                    }
                    IconButton(onClick = viewModel::send, enabled = state.canSend) {
                        if (state.sending) {
                            CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                        } else {
                            Icon(
                                Icons.AutoMirrored.Filled.Send,
                                contentDescription = stringResource(R.string.compose_send),
                                tint =
                                    if (state.canSend) {
                                        MaterialTheme.colorScheme.primary
                                    } else {
                                        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                                    },
                            )
                        }
                    }
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more_actions))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.compose_discard)) },
                            onClick = {
                                menuOpen = false
                                confirmingDiscard = true
                            },
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            if (state.savingToServer || state.sending || state.importingAttachments) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
            Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                FromPicker(
                    selected = state.draft.fromAddress,
                    addresses = state.addresses,
                    onSelect = viewModel::selectFrom,
                    onCreateNew = {
                        viewModel.loadMintableDomains()
                        showNewAddress = true
                    },
                )
                RecipientField(
                    label = stringResource(R.string.compose_to),
                    recipients = state.draft.to,
                    onAdd = { viewModel.addRecipient(RecipientField.TO, it) },
                    onRemove = { viewModel.removeRecipient(RecipientField.TO, it) },
                    suggestions = state.suggestions,
                    onQueryChange = viewModel::suggestRecipients,
                    focusRequester = toFocus,
                    trailing = {
                        TextButton(onClick = viewModel::toggleCcBcc) {
                            Text(stringResource(R.string.compose_cc_bcc_toggle))
                        }
                    },
                )
                if (state.showCcBcc) {
                    RecipientField(
                        label = stringResource(R.string.compose_cc),
                        recipients = state.draft.cc,
                        onAdd = { viewModel.addRecipient(RecipientField.CC, it) },
                        onRemove = { viewModel.removeRecipient(RecipientField.CC, it) },
                        suggestions = state.suggestions,
                        onQueryChange = viewModel::suggestRecipients,
                    )
                    RecipientField(
                        label = stringResource(R.string.compose_bcc),
                        recipients = state.draft.bcc,
                        onAdd = { viewModel.addRecipient(RecipientField.BCC, it) },
                        onRemove = { viewModel.removeRecipient(RecipientField.BCC, it) },
                        suggestions = state.suggestions,
                        onQueryChange = viewModel::suggestRecipients,
                    )
                }
                TextField(
                    value = state.draft.subject,
                    onValueChange = viewModel::updateSubject,
                    placeholder = { Text(stringResource(R.string.compose_subject)) },
                    singleLine = true,
                    colors = transparentFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
                HorizontalDivider()
                if (state.draft.attachments.isNotEmpty()) {
                    AttachmentChips(
                        attachments = state.draft.attachments,
                        onRemove = viewModel::removeAttachment,
                    )
                    if (AttachmentSizeWarning.exceedsWarning(state.draft.attachments)) {
                        AttachmentSizeWarningRow(
                            totalBytes = AttachmentSizeWarning.totalBytes(state.draft.attachments),
                        )
                    }
                }
                MarkdownToolbar(onAction = viewModel::applyMarkdown, enabled = !state.sending)
                TextField(
                    value = state.body,
                    onValueChange = viewModel::updateBody,
                    placeholder = { Text(stringResource(R.string.compose_body_hint)) },
                    textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Default),
                    colors = transparentFieldColors(),
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 240.dp),
                )
            }
        }
    }

    if (showNewAddress) {
        NewAddressSheet(
            domains = state.mintableDomains,
            creating = state.creatingAddress,
            error = state.newAddressError,
            onCreate = { username, subdomain, tld, comment ->
                viewModel.createAddress(username, subdomain, tld, comment) { showNewAddress = false }
            },
            onDismiss = { showNewAddress = false },
        )
    }

    if (confirmingDiscard) {
        AlertDialog(
            onDismissRequest = { confirmingDiscard = false },
            title = { Text(stringResource(R.string.compose_discard_confirm_title)) },
            text = { Text(stringResource(R.string.compose_discard_confirm_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDiscard = false
                        viewModel.discard()
                    },
                ) {
                    Text(stringResource(R.string.compose_discard), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDiscard = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    state.closeSaveFailure?.let { reason ->
        AlertDialog(
            onDismissRequest = viewModel::keepEditing,
            title = { Text(stringResource(R.string.compose_close_save_failed_title)) },
            text = { Text(stringResource(R.string.compose_close_save_failed_body, reason)) },
            confirmButton = {
                TextButton(onClick = viewModel::keepEditing) { Text(stringResource(R.string.compose_keep_editing)) }
            },
            dismissButton = {
                TextButton(onClick = viewModel::closeKeepingLocalCopy) {
                    Text(stringResource(R.string.compose_close_anyway))
                }
            },
        )
    }
}

@Composable
private fun transparentFieldColors() =
    TextFieldDefaults.colors(
        focusedContainerColor = Color.Transparent,
        unfocusedContainerColor = Color.Transparent,
        disabledContainerColor = Color.Transparent,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
    )

// ---------------------------------------------------------------- from

/**
 * The From picker: no preselection by default (Send stays disabled until
 * an address is chosen), favorites first, and "Create new address…" as
 * the last item — the on-the-fly From that is the point of the product.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FromPicker(
    selected: String?,
    addresses: List<Address>?,
    onSelect: (String) -> Unit,
    onCreateNew: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = Modifier.fillMaxWidth(),
    ) {
        OutlinedTextField(
            value = selected ?: "",
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.compose_from)) },
            placeholder = { Text(stringResource(R.string.compose_from_placeholder)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            singleLine = true,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (addresses == null) {
                DropdownMenuItem(
                    text = { CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(18.dp)) },
                    onClick = {},
                    enabled = false,
                )
            }
            addresses.orEmpty().filterNot { it.suspended }.forEach { address ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (address.favorite) {
                                    Text("★ ", color = MaterialTheme.colorScheme.tertiary)
                                }
                                Text(address.address)
                            }
                            if (address.comment.isNotBlank()) {
                                Text(
                                    address.comment,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    },
                    onClick = {
                        expanded = false
                        onSelect(address.address)
                    },
                )
            }
            if (addresses != null) {
                HorizontalDivider()
            }
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(R.string.compose_create_address),
                        color = MaterialTheme.colorScheme.primary,
                    )
                },
                onClick = {
                    expanded = false
                    onCreateNew()
                },
            )
        }
    }
}

// --------------------------------------------------------------- toolbar

@Composable
private fun MarkdownToolbar(
    onAction: (MarkdownAction) -> Unit,
    enabled: Boolean,
) {
    val buttons =
        listOf(
            Triple(MarkdownAction.BOLD, R.drawable.ic_format_bold, R.string.format_bold),
            Triple(MarkdownAction.ITALIC, R.drawable.ic_format_italic, R.string.format_italic),
            Triple(MarkdownAction.LINK, R.drawable.ic_link, R.string.format_link),
            Triple(MarkdownAction.BULLETS, R.drawable.ic_format_list_bulleted, R.string.format_bullets),
            Triple(MarkdownAction.NUMBERS, R.drawable.ic_format_list_numbered, R.string.format_numbers),
            Triple(MarkdownAction.QUOTE, R.drawable.ic_format_quote, R.string.format_quote),
            Triple(MarkdownAction.CODE, R.drawable.ic_code, R.string.format_code),
        )
    Row(
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
    ) {
        buttons.forEach { (action, icon, label) ->
            IconButton(onClick = { onAction(action) }, enabled = enabled) {
                Icon(painterResource(icon), contentDescription = stringResource(label))
            }
        }
        Spacer(Modifier.width(8.dp))
    }
    HorizontalDivider()
}

// ------------------------------------------------------------ attachments

@Composable
private fun AttachmentChips(
    attachments: List<DraftAttachment>,
    onRemove: (DraftAttachment) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        items(attachments, key = { it.path }) { attachment ->
            AssistChip(
                onClick = { onRemove(attachment) },
                label = {
                    Text(
                        text = "${attachment.filename} (${formatSize(attachment.size)})",
                        style = MaterialTheme.typography.labelMedium,
                    )
                },
                trailingIcon = {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = stringResource(R.string.compose_remove_attachment),
                        modifier = Modifier.size(16.dp),
                    )
                },
            )
        }
    }
}

@Composable
private fun AttachmentSizeWarningRow(totalBytes: Long) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Icon(
            Icons.Default.Warning,
            // The text beside it says the same thing; a second announcement
            // would only make TalkBack read the warning twice.
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = stringResource(R.string.compose_attachment_size_warning, formatSize(totalBytes)),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
    }
}
