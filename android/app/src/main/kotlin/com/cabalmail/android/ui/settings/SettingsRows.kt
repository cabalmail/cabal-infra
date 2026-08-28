package com.cabalmail.android.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.advanceLabelRes
import com.cabalmail.kit.settings.Accent
import com.cabalmail.kit.settings.AppTheme
import com.cabalmail.kit.settings.BodyRenderMode
import com.cabalmail.kit.settings.DefaultSort
import com.cabalmail.kit.settings.Density
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.DisposeAdvance
import com.cabalmail.kit.settings.FolderCountDisplay
import com.cabalmail.kit.settings.LoadRemoteContent
import com.cabalmail.kit.settings.MarkAsRead

// The settings row primitives and enum label mappers, shared by the
// category detail screens (SettingsScreen.kt / NotificationSettings.kt).
// Enum-valued rows open a radio dialog; free-text rows open a text dialog;
// toggles are inline.

@Composable
internal fun <T> EnumRow(
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
            ListItemDefaults.colors(
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
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
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
internal fun ToggleRow(
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
internal fun TextRow(
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
internal fun DefaultFromRow(
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
internal fun MarkAsRead.label(): String =
    stringResource(
        when (this) {
            MarkAsRead.MANUAL -> R.string.opt_mark_read_manual
            MarkAsRead.ON_OPEN -> R.string.opt_mark_read_on_open
        },
    )

@Composable
internal fun LoadRemoteContent.label(): String =
    stringResource(
        when (this) {
            LoadRemoteContent.OFF -> R.string.opt_off
            LoadRemoteContent.ASK -> R.string.opt_ask
            LoadRemoteContent.ALWAYS -> R.string.opt_always
        },
    )

@Composable
internal fun BodyRenderMode.label(): String =
    stringResource(
        when (this) {
            BodyRenderMode.ORIGINAL -> R.string.opt_render_original
            BodyRenderMode.READER -> R.string.opt_render_reader
        },
    )

@Composable
internal fun FolderCountDisplay.label(): String =
    stringResource(
        when (this) {
            FolderCountDisplay.UNREAD -> R.string.opt_count_unread
            FolderCountDisplay.TOTAL -> R.string.opt_count_total
            FolderCountDisplay.BOTH -> R.string.opt_count_both
        },
    )

@Composable
internal fun DefaultSort.label(): String =
    stringResource(
        when (this) {
            DefaultSort.RECEIVED -> R.string.opt_sort_received
            DefaultSort.SENT -> R.string.opt_sort_sent
            DefaultSort.FROM -> R.string.opt_sort_from
            DefaultSort.SUBJECT -> R.string.opt_sort_subject
        },
    )

@Composable
internal fun DisposeAction.label(): String =
    stringResource(
        when (this) {
            DisposeAction.ARCHIVE -> R.string.archive
            DisposeAction.TRASH -> R.string.opt_dispose_trash
        },
    )

@Composable
internal fun DisposeAdvance.label(): String = stringResource(advanceLabelRes(this))

@Composable
internal fun AppTheme.label(): String =
    stringResource(
        when (this) {
            AppTheme.SYSTEM -> R.string.opt_theme_system
            AppTheme.LIGHT -> R.string.opt_theme_light
            AppTheme.DARK -> R.string.opt_theme_dark
        },
    )

@Composable
internal fun Accent.label(): String =
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
internal fun Density.label(): String =
    stringResource(
        when (this) {
            Density.COMPACT -> R.string.opt_density_compact
            Density.NORMAL -> R.string.opt_density_normal
            Density.ROOMY -> R.string.opt_density_roomy
        },
    )
