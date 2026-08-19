package com.cabalmail.android.ui.settings

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.cabalmail.android.BuildConfig
import com.cabalmail.android.R
import com.cabalmail.android.notifications.NewMailSync
import com.cabalmail.kit.settings.Accent
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.AppTheme
import com.cabalmail.kit.settings.BodyRenderMode
import com.cabalmail.kit.settings.DefaultSort
import com.cabalmail.kit.settings.Density
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.FolderCountDisplay
import com.cabalmail.kit.settings.LoadRemoteContent
import com.cabalmail.kit.settings.MarkAsRead

private const val ISSUES_URL = "https://github.com/cabalmail/cabal-infra/issues"

/**
 * Settings (plan §6.3): Account, Reading, Composing, Actions, Appearance,
 * About. Enum-valued rows open a radio dialog; free-text rows open a text
 * dialog; toggles are inline. Every change writes through the preference
 * repository (DataStore now, server on a short debounce).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
    onSignOut: () -> Unit,
    /** Null when hosted as a top-level destination (no back arrow). */
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                            )
                        }
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize().verticalScroll(rememberScrollState())) {
            SectionHeader(stringResource(R.string.settings_account))
            ListItem(
                headlineContent = { Text(state.username ?: "") },
                supportingContent = { Text(stringResource(R.string.settings_signed_in_as)) },
            )
            ListItem(
                headlineContent = { Text(state.controlDomain ?: "") },
                supportingContent = { Text(stringResource(R.string.settings_server)) },
            )
            TextRow(
                title = stringResource(R.string.settings_display_name),
                value = preferences.displayName,
                empty = stringResource(R.string.settings_display_name_empty),
                singleLine = true,
                onChange = { name -> onUpdate { it.copy(displayName = name.trim()) } },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.sign_out), color = MaterialTheme.colorScheme.error) },
                modifier = Modifier.clickable(onClick = onSignOut),
            )

            SectionHeader(stringResource(R.string.settings_reading))
            EnumRow(
                title = stringResource(R.string.settings_mark_as_read),
                value = preferences.markAsRead,
                options = MarkAsRead.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(markAsRead = value) } },
            )
            EnumRow(
                title = stringResource(R.string.settings_load_remote_content),
                value = preferences.loadRemoteContent,
                options = LoadRemoteContent.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(loadRemoteContent = value) } },
            )
            EnumRow(
                title = stringResource(R.string.settings_render_mode),
                value = preferences.bodyRenderMode,
                options = BodyRenderMode.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(bodyRenderMode = value) } },
            )
            EnumRow(
                title = stringResource(R.string.settings_folder_count),
                value = preferences.folderCountDisplay,
                options = FolderCountDisplay.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(folderCountDisplay = value) } },
            )
            EnumRow(
                title = stringResource(R.string.settings_default_sort),
                value = preferences.defaultSort,
                options = DefaultSort.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(defaultSort = value) } },
            )
            ToggleRow(
                title = stringResource(R.string.sort_descending),
                checked = preferences.defaultSortDescending,
                onChange = { value -> onUpdate { it.copy(defaultSortDescending = value) } },
            )

            SectionHeader(stringResource(R.string.settings_composing))
            DefaultFromRow(
                value = preferences.defaultFromAddress,
                addresses = state.addresses?.map { it.address }.orEmpty(),
                onSelect = { value -> onUpdate { it.copy(defaultFromAddress = value) } },
            )
            TextRow(
                title = stringResource(R.string.settings_signature),
                value = preferences.signature,
                empty = stringResource(R.string.settings_signature_empty),
                singleLine = false,
                onChange = { signature -> onUpdate { it.copy(signature = signature) } },
            )

            SectionHeader(stringResource(R.string.settings_actions))
            EnumRow(
                title = stringResource(R.string.settings_dispose_action),
                value = preferences.disposeAction,
                options = DisposeAction.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(disposeAction = value) } },
            )

            SectionHeader(stringResource(R.string.settings_notifications))
            NotificationsRow(
                enabled = preferences.notificationsEnabled,
                onChange = { value -> onUpdate { it.copy(notificationsEnabled = value) } },
            )

            SectionHeader(stringResource(R.string.settings_appearance))
            EnumRow(
                title = stringResource(R.string.settings_theme),
                value = preferences.theme,
                options = AppTheme.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(theme = value) } },
            )
            ToggleRow(
                title = stringResource(R.string.settings_dynamic_color),
                checked = preferences.dynamicColor,
                onChange = { value -> onUpdate { it.copy(dynamicColor = value) } },
                supporting = stringResource(R.string.settings_dynamic_color_hint),
            )
            EnumRow(
                title = stringResource(R.string.settings_accent),
                value = preferences.accent,
                options = Accent.entries,
                label = { it.label() },
                enabled = !preferences.dynamicColor,
                onSelect = { value -> onUpdate { it.copy(accent = value) } },
            )
            EnumRow(
                title = stringResource(R.string.settings_density),
                value = preferences.density,
                options = Density.entries,
                label = { it.label() },
                onSelect = { value -> onUpdate { it.copy(density = value) } },
            )

            SectionHeader(stringResource(R.string.settings_about))
            ListItem(
                headlineContent = { Text(stringResource(R.string.settings_version)) },
                supportingContent = { Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.settings_report_issue)) },
                supportingContent = { Text(ISSUES_URL) },
                modifier =
                    Modifier.clickable {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, ISSUES_URL.toUri())) }
                    },
            )
        }
    }
}

// --------------------------------------------------------------- rows

/**
 * The new-mail toggle (plan §7.3): turning it on asks for the notification
 * permission on API 33+ and schedules the periodic sync; off cancels it.
 */
@Composable
private fun NotificationsRow(
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    val context = LocalContext.current
    var denied by remember { mutableStateOf(false) }
    val enable = {
        NewMailSync.clearBaseline(context)
        NewMailSync.schedule(context, enabled = true)
        onChange(true)
    }
    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) enable() else denied = true
        }
    ToggleRow(
        title = stringResource(R.string.settings_new_mail_notifications),
        checked = enabled,
        supporting =
            if (denied) {
                stringResource(R.string.settings_notifications_denied)
            } else {
                stringResource(R.string.settings_new_mail_notifications_hint)
            },
        onChange = { value ->
            if (!value) {
                NewMailSync.schedule(context, enabled = false)
                onChange(false)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !NewMailSync.canPost(context)) {
                permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                enable()
            }
        },
    )
}

@Composable
private fun SectionHeader(title: String) {
    HorizontalDivider()
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun <T> EnumRow(
    title: String,
    value: T,
    options: List<T>,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    enabled: Boolean = true,
) {
    var open by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(label(value)) },
        modifier = Modifier.clickable(enabled = enabled) { open = true },
        colors =
            androidx.compose.material3.ListItemDefaults.colors(
                headlineColor =
                    if (enabled) {
                        MaterialTheme.colorScheme.onSurface
                    } else {
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                    },
            ),
    )
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(title) },
            text = {
                Column {
                    options.forEach { option ->
                        androidx.compose.foundation.layout.Row(
                            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .selectable(
                                        selected = option == value,
                                        onClick = {
                                            open = false
                                            onSelect(option)
                                        },
                                    ).padding(vertical = 6.dp),
                        ) {
                            RadioButton(selected = option == value, onClick = null)
                            Text(label(option), modifier = Modifier.padding(start = 12.dp))
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { open = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun ToggleRow(
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    supporting: String? = null,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = supporting?.let { { Text(it) } },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange) },
        modifier = Modifier.clickable { onChange(!checked) },
    )
}

@Composable
private fun TextRow(
    title: String,
    value: String,
    empty: String,
    singleLine: Boolean,
    onChange: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var draft by remember(value, open) { mutableStateOf(value) }
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(value.ifBlank { empty }, maxLines = 3) },
        modifier = Modifier.clickable { open = true },
    )
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(title) },
            text = {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = singleLine,
                    minLines = if (singleLine) 1 else 3,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        open = false
                        onChange(draft)
                    },
                ) {
                    Text(stringResource(R.string.settings_save))
                }
            },
            dismissButton = {
                TextButton(onClick = { open = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun DefaultFromRow(
    value: String?,
    addresses: List<String>,
    onSelect: (String?) -> Unit,
) {
    val none = stringResource(R.string.settings_default_from_none)
    // "None" first, then the owned addresses; a stale value still shows.
    val options = listOf<String?>(null) + (addresses + listOfNotNull(value)).distinct()
    EnumRow(
        title = stringResource(R.string.settings_default_from),
        value = value,
        options = options,
        label = { it ?: none },
        onSelect = onSelect,
    )
}

// ------------------------------------------------------------- labels

@Composable
private fun MarkAsRead.label(): String =
    stringResource(
        when (this) {
            MarkAsRead.MANUAL -> R.string.opt_mark_read_manual
            MarkAsRead.ON_OPEN -> R.string.opt_mark_read_on_open
        },
    )

@Composable
private fun LoadRemoteContent.label(): String =
    stringResource(
        when (this) {
            LoadRemoteContent.OFF -> R.string.opt_off
            LoadRemoteContent.ASK -> R.string.opt_ask
            LoadRemoteContent.ALWAYS -> R.string.opt_always
        },
    )

@Composable
private fun BodyRenderMode.label(): String =
    stringResource(
        when (this) {
            BodyRenderMode.ORIGINAL -> R.string.opt_render_original
            BodyRenderMode.READER -> R.string.opt_render_reader
        },
    )

@Composable
private fun FolderCountDisplay.label(): String =
    stringResource(
        when (this) {
            FolderCountDisplay.UNREAD -> R.string.opt_count_unread
            FolderCountDisplay.TOTAL -> R.string.opt_count_total
            FolderCountDisplay.BOTH -> R.string.opt_count_both
        },
    )

@Composable
private fun DefaultSort.label(): String =
    stringResource(
        when (this) {
            DefaultSort.RECEIVED -> R.string.opt_sort_received
            DefaultSort.SENT -> R.string.opt_sort_sent
            DefaultSort.FROM -> R.string.opt_sort_from
            DefaultSort.SUBJECT -> R.string.opt_sort_subject
        },
    )

@Composable
private fun DisposeAction.label(): String =
    stringResource(
        when (this) {
            DisposeAction.ARCHIVE -> R.string.archive
            DisposeAction.TRASH -> R.string.opt_dispose_trash
        },
    )

@Composable
private fun AppTheme.label(): String =
    stringResource(
        when (this) {
            AppTheme.SYSTEM -> R.string.opt_theme_system
            AppTheme.LIGHT -> R.string.opt_theme_light
            AppTheme.DARK -> R.string.opt_theme_dark
        },
    )

@Composable
private fun Accent.label(): String =
    stringResource(
        when (this) {
            Accent.INK -> R.string.opt_accent_ink
            Accent.OXBLOOD -> R.string.opt_accent_oxblood
            Accent.FOREST -> R.string.opt_accent_forest
            Accent.AZURE -> R.string.opt_accent_azure
            Accent.AMBER -> R.string.opt_accent_amber
            Accent.PLUM -> R.string.opt_accent_plum
        },
    )

@Composable
private fun Density.label(): String =
    stringResource(
        when (this) {
            Density.COMPACT -> R.string.opt_density_compact
            Density.NORMAL -> R.string.opt_density_normal
            Density.ROOMY -> R.string.opt_density_roomy
        },
    )
