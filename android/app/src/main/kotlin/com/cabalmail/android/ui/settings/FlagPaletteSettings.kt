package com.cabalmail.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The custom-flag palette manager (rules-composition plan, Phase 3): up to
 * 20 named, colored flags on fixed slot atoms. All edits write through the
 * preference repository like any other setting; renames and recolors are
 * metadata edits that touch zero messages. Reordering uses per-row up/down
 * buttons (disabled at the ends, never hidden — rows keep a stable
 * footprint), matching the rules list.
 */
@Composable
internal fun FlagPaletteSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    val palette = preferences.flagPalette
    var editingSlot by rememberSaveable { mutableStateOf<String?>(null) }

    palette.forEachIndexed { index, entry ->
        ListItem(
            leadingContent = {
                Box(
                    modifier =
                        Modifier
                            .size(20.dp)
                            .clip(CircleShape)
                            .background(flagColor(entry.color)),
                )
            },
            headlineContent = { Text(entry.label) },
            supportingContent =
                if (entry.enabled) {
                    null
                } else {
                    { Text(stringResource(R.string.flags_disabled)) }
                },
            trailingContent = {
                Row {
                    IconButton(
                        onClick = { onUpdate { it.copy(flagPalette = it.flagPalette.moved(index, -1)) } },
                        enabled = index > 0,
                    ) {
                        Icon(
                            Icons.Default.KeyboardArrowUp,
                            contentDescription = stringResource(R.string.flags_move_up),
                        )
                    }
                    IconButton(
                        onClick = { onUpdate { it.copy(flagPalette = it.flagPalette.moved(index, 1)) } },
                        enabled = index < palette.size - 1,
                    ) {
                        Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = stringResource(R.string.flags_move_down),
                        )
                    }
                }
            },
            modifier = Modifier.clickable { editingSlot = entry.slot },
        )
    }
    if (FlagPalette.firstFreeSlot(palette) != null) {
        val newLabel = stringResource(R.string.flags_new_label)
        TextButton(
            onClick = {
                onUpdate { prefs ->
                    val slot =
                        FlagPalette.firstFreeSlot(prefs.flagPalette) ?: return@onUpdate prefs
                    prefs.copy(
                        flagPalette =
                            prefs.flagPalette +
                                FlagPaletteEntry(slot = slot, label = newLabel, color = FlagPalette.COLORS.first()),
                    )
                }
            },
            modifier = Modifier.padding(horizontal = 8.dp),
        ) { Text(stringResource(R.string.flags_add)) }
    }
    Text(
        stringResource(
            if (palette.isEmpty()) R.string.flags_empty_hint else R.string.flags_footer,
        ),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )

    val editing = palette.firstOrNull { it.slot == editingSlot }
    if (editing != null) {
        FlagEditorDialog(
            entry = editing,
            onChange = { changed ->
                onUpdate { prefs ->
                    prefs.copy(
                        flagPalette = prefs.flagPalette.map { if (it.slot == changed.slot) changed else it },
                    )
                }
            },
            onDelete = {
                val slot = editing.slot
                editingSlot = null
                onUpdate { prefs ->
                    prefs.copy(flagPalette = prefs.flagPalette.filterNot { it.slot == slot })
                }
            },
            onDismiss = { editingSlot = null },
        )
    }
}

/** Label, color, enabled, and the only route to deletion — behind a
 * confirmation, because per-message tags on a retired slot outlive the
 * palette entry. */
@Composable
private fun FlagEditorDialog(
    entry: FlagPaletteEntry,
    onChange: (FlagPaletteEntry) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    var confirmingDelete by rememberSaveable { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.flags_edit)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = entry.label,
                    onValueChange = { value ->
                        onChange(entry.copy(label = value.take(FlagPalette.MAX_LABEL_LENGTH)))
                    },
                    label = { Text(stringResource(R.string.flags_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.flags_color), style = MaterialTheme.typography.titleSmall)
                ColorSwatches(selectedColor = entry.color, onSelect = { onChange(entry.copy(color = it)) })
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.flags_enabled), modifier = Modifier.weight(1f))
                    Switch(checked = entry.enabled, onCheckedChange = { onChange(entry.copy(enabled = it)) })
                }
                Text(
                    stringResource(R.string.flags_enabled_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(onClick = { confirmingDelete = true }) {
                    Text(stringResource(R.string.flags_delete), color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.rules_done)) }
        },
    )
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text(stringResource(R.string.flags_delete_title, entry.label)) },
            text = { Text(stringResource(R.string.flags_delete_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingDelete = false
                    onDelete()
                }) { Text(stringResource(R.string.flags_delete), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

/** The ten wire colors as tappable swatches, five per row. */
@Composable
private fun ColorSwatches(
    selectedColor: String,
    onSelect: (String) -> Unit,
) {
    FlagPalette.COLORS.chunked(5).forEach { rowColors ->
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            rowColors.forEach { name ->
                val isSelected = name == selectedColor
                Box(
                    contentAlignment = Alignment.Center,
                    modifier =
                        Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(flagColor(name))
                            .semantics {
                                contentDescription = name
                                selected = isSelected
                            }.clickable { onSelect(name) },
                ) {
                    if (isSelected) {
                        Icon(
                            Icons.Default.Check,
                            contentDescription = null,
                            tint = Color.White,
                        )
                    }
                }
            }
        }
    }
}

/** Moves the element at [index] by [delta], clamped no-op at the ends. */
private fun List<FlagPaletteEntry>.moved(
    index: Int,
    delta: Int,
): List<FlagPaletteEntry> {
    val target = index + delta
    if (index !in indices || target !in indices) return this
    return toMutableList().apply { add(target, removeAt(index)) }
}

/**
 * Maps the wire color vocabulary onto fixed render colors (the palette is
 * cross-client, so these are not themed). Unknown names — a newer server's
 * vocabulary — render gray but round-trip unchanged.
 */
internal fun flagColor(name: String): Color =
    when (name) {
        "red" -> Color(0xFFD32F2F)
        "orange" -> Color(0xFFF57C00)
        "yellow" -> Color(0xFFF9A825)
        "green" -> Color(0xFF388E3C)
        "teal" -> Color(0xFF00897B)
        "blue" -> Color(0xFF1976D2)
        "indigo" -> Color(0xFF3949AB)
        "purple" -> Color(0xFF8E24AA)
        "pink" -> Color(0xFFD81B60)
        else -> Color(0xFF757575)
    }
