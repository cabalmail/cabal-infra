package com.cabalmail.android.ui.feeds

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.cabalmail.android.R
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import kotlinx.coroutines.launch

/**
 * The feed management overlays, hosted once per screen that offers
 * management: the subscribe, folder, and settings sheets; the unsubscribe,
 * delete-folder, and mark-all-read confirmations; the OPML document picker
 * and export share; and the one-shot notices on [snackbarHostState]. The
 * view model decides what is up; this turns it into Compose.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedManagementSheets(
    viewModel: FeedManagementViewModel,
    snackbarHostState: SnackbarHostState,
    /** Navigates to a feed the user just subscribed to. */
    onSubscribed: (RssSubscription) -> Unit = {},
    /** The scope on screen may be gone; the host leaves it. */
    onUnsubscribed: () -> Unit = {},
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val unreadable = stringResource(R.string.feed_opml_unreadable)

    // OPML import: the picker is raised on the model's request, the file read here, the text sent back.
    val importPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            val folderId = state.importFolderId
            if (uri != null) {
                scope.launch {
                    val text = FeedOpmlFiles.readText(context, uri)
                    if (text ==
                        null
                    ) {
                        snackbarHostState.showSnackbar(unreadable)
                    } else {
                        viewModel.importOpml(text, folderId)
                    }
                }
            }
        }
    LaunchedEffect(state.importRequested) {
        if (state.importRequested) {
            viewModel.consumeImportRequest()
            importPicker.launch(
                arrayOf("text/x-opml", "text/xml", "application/xml", "application/octet-stream", "*/*"),
            )
        }
    }

    // Notices: subscribe / unsubscribe as snackbars, the import result as a dialog, the export as a share.
    val subscribedText =
        (state.notice as? FeedNotice.Subscribed)?.let { notice ->
            stringResource(
                if (notice.existing) R.string.feed_already_subscribed_notice else R.string.feed_subscribed_notice,
                notice.subscription.displayTitle,
            )
        }
    val unsubscribedText = stringResource(R.string.feed_unsubscribed_notice)
    LaunchedEffect(state.notice) {
        when (val notice = state.notice) {
            null -> Unit
            is FeedNotice.Subscribed -> {
                viewModel.clearNotice()
                onSubscribed(notice.subscription)
                snackbarHostState.showSnackbar(subscribedText.orEmpty())
            }
            FeedNotice.Unsubscribed -> {
                viewModel.clearNotice()
                onUnsubscribed()
                snackbarHostState.showSnackbar(unsubscribedText)
            }
            is FeedNotice.OpmlExported -> {
                viewModel.clearNotice()
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", notice.file)
                val send =
                    Intent(Intent.ACTION_SEND)
                        .setType("text/xml")
                        .putExtra(Intent.EXTRA_STREAM, uri)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                runCatching { context.startActivity(Intent.createChooser(send, null)) }
            }
            is FeedNotice.OpmlImported -> Unit
        }
    }
    (state.notice as? FeedNotice.OpmlImported)?.let { notice ->
        AlertDialog(
            onDismissRequest = viewModel::clearNotice,
            title = { Text(stringResource(R.string.feed_opml_result_title)) },
            text = { Text(FeedOpmlSummary.text(notice.result)) },
            confirmButton = {
                TextButton(
                    onClick = viewModel::clearNotice,
                ) { Text(stringResource(android.R.string.ok)) }
            },
        )
    }
    // An error outside a sheet (a menu action) surfaces as a snackbar.
    LaunchedEffect(state.error, state.sheet) {
        val message = state.error ?: return@LaunchedEffect
        if (state.sheet == null) {
            viewModel.clearError()
            snackbarHostState.showSnackbar(message)
        }
    }

    when (val sheet = state.sheet) {
        null -> Unit
        is FeedSheet.Subscribe ->
            ModalBottomSheet(onDismissRequest = viewModel::dismissSheet) {
                SubscribeFeedSheet(
                    folders = state.folders,
                    initialFolderId = sheet.folderId,
                    busy = state.busy,
                    error = state.error,
                    onSubscribe = viewModel::subscribe,
                    onDismiss = viewModel::dismissSheet,
                )
            }
        is FeedSheet.Folder ->
            ModalBottomSheet(onDismissRequest = viewModel::dismissSheet) {
                FeedFolderSheet(
                    folders = state.folders,
                    editing = sheet.editing,
                    initialParentId = sheet.parentId,
                    busy = state.busy,
                    error = state.error,
                    onCreate = viewModel::createFolder,
                    onUpdate = viewModel::updateFolder,
                    onDismiss = viewModel::dismissSheet,
                )
            }
        is FeedSheet.Settings ->
            ModalBottomSheet(onDismissRequest = viewModel::dismissSheet) {
                FeedSubscriptionSettingsSheet(
                    subscription = sheet.subscription,
                    folders = state.folders,
                    busy = state.busy,
                    error = state.error,
                    onSave = { update -> viewModel.updateSubscription(sheet.subscription, update) },
                    onUnsubscribe = { viewModel.confirm(FeedConfirm.Unsubscribe(sheet.subscription)) },
                    onDismiss = viewModel::dismissSheet,
                )
            }
    }

    when (val confirm = state.confirm) {
        null -> Unit
        is FeedConfirm.Unsubscribe ->
            ConfirmDialog(
                title = stringResource(R.string.feed_unsubscribe_title, confirm.subscription.displayTitle),
                body = stringResource(R.string.feed_unsubscribe_body),
                confirmLabel = stringResource(R.string.feed_settings_unsubscribe),
                destructive = true,
                busy = state.busy,
                onConfirm = { viewModel.unsubscribe(confirm.subscription) },
                onDismiss = viewModel::dismissConfirm,
            )
        is FeedConfirm.DeleteFolder ->
            ConfirmDialog(
                title = stringResource(R.string.feed_delete_folder_title, confirm.folder.name),
                body = stringResource(R.string.feed_delete_folder_body),
                confirmLabel = stringResource(R.string.feed_delete_folder_confirm),
                destructive = true,
                busy = state.busy,
                onConfirm = { viewModel.deleteFolder(confirm.folder) },
                onDismiss = viewModel::dismissConfirm,
            )
        is FeedConfirm.MarkAllRead ->
            ConfirmDialog(
                title = stringResource(R.string.feed_mark_all_read_title, confirm.title),
                body = stringResource(R.string.feed_mark_all_read_body),
                confirmLabel = stringResource(R.string.feed_mark_all_read_confirm),
                destructive = false,
                busy = false,
                onConfirm = { viewModel.markAllRead(confirm.scope) },
                onDismiss = viewModel::dismissConfirm,
            )
    }
}

@Composable
private fun ConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    destructive: Boolean,
    busy: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = !busy) {
                Text(
                    confirmLabel,
                    color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                )
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** "None (top level)" then the folder tree, indented four spaces per level, as a read-only dropdown. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FeedFolderPicker(
    label: String,
    folders: List<RssFolder>,
    selectedId: String,
    onSelect: (String) -> Unit,
    excluding: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    val choices = remember(folders, excluding) { FeedFormRules.folderChoices(folders, excluding) }
    val none = stringResource(R.string.feed_folder_none)
    val selectedLabel = choices.firstOrNull { it.folder.folderId == selectedId }?.folder?.name ?: none
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(none) },
                onClick = {
                    open = false
                    onSelect("")
                },
            )
            choices.forEach { choice ->
                DropdownMenuItem(
                    text = { Text("    ".repeat(choice.depth) + choice.folder.name) },
                    onClick = {
                        open = false
                        onSelect(choice.folder.folderId)
                    },
                )
            }
        }
    }
}

/** A read-only dropdown over an enum, for the settings sheet's Reading section. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> EnumPicker(
    label: String,
    value: T,
    options: List<T>,
    optionLabel: @Composable (T) -> String,
    onSelect: (T) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = optionLabel(value),
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(optionLabel(option)) },
                    onClick = {
                        open = false
                        onSelect(option)
                    },
                )
            }
        }
    }
}

@Composable
private fun SheetColumn(content: @Composable () -> Unit) {
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .navigationBarsPadding()
                .imePadding(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        content()
        Spacer(modifier = Modifier.height(16.dp))
    }
}

@Composable
private fun SheetButtons(
    submitLabel: String,
    canSubmit: Boolean,
    busy: Boolean,
    onSubmit: () -> Unit,
    onDismiss: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
        TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        Button(onClick = onSubmit, enabled = canSubmit && !busy) {
            if (busy) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.height(18.dp))
            } else {
                Text(submitLabel)
            }
        }
    }
}

@Composable
internal fun SubscribeFeedSheet(
    folders: List<RssFolder>,
    initialFolderId: String,
    busy: Boolean,
    error: String?,
    onSubscribe: (url: String, folderId: String) -> Unit,
    onDismiss: () -> Unit,
) {
    var url by rememberSaveable { mutableStateOf("") }
    var folderId by rememberSaveable(initialFolderId) { mutableStateOf(initialFolderId) }
    val normalized = FeedFormRules.normalizedFeedUrl(url)
    SheetColumn {
        Text(stringResource(R.string.feed_subscribe_title), style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(
            value = url,
            onValueChange = { url = it },
            singleLine = true,
            label = { Text(stringResource(R.string.feed_subscribe_address)) },
            placeholder = { Text(stringResource(R.string.feed_subscribe_hint)) },
            keyboardOptions =
                KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
            modifier = Modifier.fillMaxWidth(),
        )
        FeedFolderPicker(
            label = stringResource(R.string.feed_folder_label),
            folders = folders,
            selectedId = folderId,
            onSelect = { folderId = it },
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        SheetButtons(
            submitLabel = stringResource(R.string.feed_subscribe_action),
            canSubmit = normalized != null,
            busy = busy,
            onSubmit = { normalized?.let { onSubscribe(it, folderId) } },
            onDismiss = onDismiss,
        )
    }
}

@Composable
internal fun FeedFolderSheet(
    folders: List<RssFolder>,
    editing: RssFolder?,
    initialParentId: String,
    busy: Boolean,
    error: String?,
    onCreate: (name: String, parentId: String) -> Unit,
    onUpdate: (RssFolder, com.cabalmail.kit.models.RssFolderUpdate) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by rememberSaveable(editing?.folderId) { mutableStateOf(editing?.name.orEmpty()) }
    var parentId by rememberSaveable(editing?.folderId, initialParentId) { mutableStateOf(initialParentId) }
    val update = editing?.let { FeedFormRules.folderUpdate(it, name, parentId) }
    val canSubmit = if (editing == null) name.isNotBlank() else update != null
    SheetColumn {
        Text(
            stringResource(if (editing == null) R.string.feed_folder_new_title else R.string.feed_folder_edit_title),
            style = MaterialTheme.typography.titleLarge,
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            singleLine = true,
            label = { Text(stringResource(R.string.feed_folder_name)) },
            placeholder = { Text(stringResource(R.string.feed_folder_name_hint)) },
            modifier = Modifier.fillMaxWidth(),
        )
        FeedFolderPicker(
            label = stringResource(R.string.feed_folder_parent),
            folders = folders,
            selectedId = parentId,
            onSelect = { parentId = it },
            excluding = editing?.folderId,
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        SheetButtons(
            submitLabel = stringResource(if (editing == null) R.string.feed_folder_create else R.string.save),
            canSubmit = canSubmit,
            busy = busy,
            onSubmit = {
                if (editing == null) onCreate(name, parentId) else update?.let { onUpdate(editing, it) }
            },
            onDismiss = onDismiss,
        )
    }
}

@Composable
internal fun FeedSubscriptionSettingsSheet(
    subscription: RssSubscription,
    folders: List<RssFolder>,
    busy: Boolean,
    error: String?,
    onSave: (com.cabalmail.kit.models.RssSubscriptionUpdate) -> Unit,
    onUnsubscribe: () -> Unit,
    onDismiss: () -> Unit,
) {
    val key = subscription.subscriptionId
    var title by rememberSaveable(key) { mutableStateOf(subscription.customTitle) }
    var folderId by rememberSaveable(key) { mutableStateOf(subscription.folderId) }
    var ordering by rememberSaveable(key) { mutableStateOf(subscription.orderingMode) }
    var openMode by rememberSaveable(key) { mutableStateOf(subscription.defaultOpenMode) }
    var styling by rememberSaveable(key) { mutableStateOf(subscription.defaultStyling) }
    var remote by rememberSaveable(key) { mutableStateOf(subscription.defaultRemoteContent) }
    val update = FeedFormRules.settingsUpdate(subscription, title, folderId, ordering, openMode, styling, remote)
    val context = LocalContext.current
    SheetColumn {
        Text(subscription.displayTitle, style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            singleLine = true,
            label = { Text(stringResource(R.string.feed_settings_title_label)) },
            placeholder = {
                Text(
                    subscription.feed?.title?.ifEmpty { null } ?: stringResource(R.string.feed_settings_title_hint),
                )
            },
            modifier = Modifier.fillMaxWidth(),
        )
        FeedFolderPicker(
            label = stringResource(R.string.feed_folder_label),
            folders = folders,
            selectedId = folderId,
            onSelect = { folderId = it },
        )
        Text(stringResource(R.string.feed_settings_reading), style = MaterialTheme.typography.titleSmall)
        EnumPicker(stringResource(R.string.feed_order), ordering, RssOrderingMode.entries, { it.label() }) {
            ordering =
                it
        }
        EnumPicker(stringResource(R.string.feed_settings_open), openMode, RssOpenMode.entries, { it.label() }) {
            openMode =
                it
        }
        EnumPicker(stringResource(R.string.feed_settings_styling), styling, RssStyling.entries, { it.label() }) {
            styling =
                it
        }
        EnumPicker(
            stringResource(R.string.feed_settings_remote),
            remote,
            RssRemoteContentMode.entries,
            { it.label() },
        ) {
            remote = it
        }
        Text(stringResource(R.string.feed_settings_feed), style = MaterialTheme.typography.titleSmall)
        val feed = subscription.feed
        if (feed == null) {
            Text(
                stringResource(R.string.feed_settings_no_details),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            FeedDetailRow(stringResource(R.string.feed_settings_address), feed.canonicalUrl)
            if (feed.siteUrl.isNotEmpty()) {
                TextButton(
                    onClick = {
                        runCatching {
                            context.startActivity(
                                Intent(Intent.ACTION_VIEW, feed.siteUrl.toUri()),
                            )
                        }
                    },
                ) { Text(stringResource(R.string.feed_settings_site) + ": " + feed.siteUrl, maxLines = 1) }
            }
            FeedDetailRow(stringResource(R.string.feed_settings_status), FeedHealthText.status(feed))
            if (feed.lastError.isNotEmpty() && feed.consecutiveFailureCount > 0) {
                Text(
                    feed.lastError,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            FeedDetailRow(stringResource(R.string.feed_settings_last_fetched), FeedHealthText.lastFetched(feed))
            FeedDetailRow(stringResource(R.string.feed_settings_checks), FeedHealthText.cadence(feed))
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        HorizontalDivider()
        OutlinedButton(onClick = onUnsubscribe, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.feed_settings_unsubscribe), color = MaterialTheme.colorScheme.error)
        }
        SheetButtons(
            submitLabel = stringResource(R.string.save),
            canSubmit = update != null,
            busy = busy,
            onSubmit = { update?.let(onSave) },
            onDismiss = onDismiss,
        )
    }
}

@Composable
private fun FeedDetailRow(
    label: String,
    value: String,
) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            modifier = Modifier.padding(start = 16.dp).weight(1f, fill = false),
        )
    }
}
