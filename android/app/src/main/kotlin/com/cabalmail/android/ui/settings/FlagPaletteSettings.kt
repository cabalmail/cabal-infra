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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import com.cabalmail.android.ui.theme.ColorTokens
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The flag palette manager: the built-in flag's entry, "Flagged" until the
 * user renames it, and up to 20 named, colored flags on fixed slot atoms
 * (rules-composition plan, Phase 3; unified-flags plan). All edits write
 * through the preference repository like any other setting; renames and
 * recolors are metadata edits that touch zero messages.
 *
 * The list is the effective palette ([FlagPalette.effective]), so the
 * built-in entry is always a row, whether or not it has been stored yet. It
 * renames, recolors and moves like the others, and resets where they
 * delete. Every edit goes through [FlagPaletteEdits].
 *
 * The first entry is the default flag, the one the swipe, the star
 * button and the flag shortcut set (`FlagToggle`). Its row says so once
 * there is a second flag to tell it from, and every other flag's dialog
 * offers Make default, which moves that flag to the top.
 *
 * Reordering uses per-row up/down buttons (disabled at the ends, never
 * hidden — rows keep a stable footprint), matching the rules list.
 */
@Composable
internal fun FlagPaletteSettings(
    preferences: AppPreferences,
    onUpdate: ((AppPreferences) -> AppPreferences) -> Unit,
) {
    val palette = FlagPalette.effective(preferences.flagPalette)
    // The Default mark needs a second flag to mean anything.
    val defaultSlot = FlagPalette.defaultEntry(preferences.flagPalette).slot.takeIf { palette.size > 1 }
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
                if (entry.slot == defaultSlot) {
                    { Text(stringResource(R.string.flags_default)) }
                } else {
                    null
                },
            trailingContent = {
                Row {
                    IconButton(
                        onClick = {
                            onUpdate { it.copy(flagPalette = FlagPaletteEdits.moved(it.flagPalette, entry.slot, -1)) }
                        },
                        enabled = index > 0,
                    ) {
                        Icon(
                            Icons.Default.KeyboardArrowUp,
                            contentDescription = stringResource(R.string.flags_move_up),
                        )
                    }
                    IconButton(
                        onClick = {
                            onUpdate { it.copy(flagPalette = FlagPaletteEdits.moved(it.flagPalette, entry.slot, 1)) }
                        },
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
            onClick = { onUpdate { it.copy(flagPalette = FlagPaletteEdits.added(it.flagPalette, newLabel)) } },
            modifier = Modifier.padding(horizontal = 8.dp),
        ) { Text(stringResource(R.string.flags_add)) }
    }
    Text(
        // While the user has added no flag of their own the list holds the
        // built-in entry alone, and there is no order to explain.
        stringResource(
            if (FlagPalette.keywordEntries(palette).isEmpty()) R.string.flags_empty_hint else R.string.flags_footer,
        ),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )

    val editing = palette.firstOrNull { it.slot == editingSlot }
    if (editing != null) {
        FlagEditorDialog(
            entry = editing,
            canReset = FlagPaletteEdits.canReset(preferences.flagPalette),
            canMakeDefault = FlagPaletteEdits.canMakeDefault(preferences.flagPalette, editing.slot),
            onMakeDefault = {
                val slot = editing.slot
                onUpdate { it.copy(flagPalette = FlagPaletteEdits.madeDefault(it.flagPalette, slot)) }
            },
            onChange = { changed ->
                onUpdate { it.copy(flagPalette = FlagPaletteEdits.changed(it.flagPalette, changed)) }
            },
            onDelete = {
                val slot = editing.slot
                editingSlot = null
                onUpdate { it.copy(flagPalette = FlagPaletteEdits.deleted(it.flagPalette, slot)) }
            },
            // Reset leaves the dialog open: the entry is still there, back
            // under its default name and color.
            onReset = { onUpdate { it.copy(flagPalette = FlagPaletteEdits.reset(it.flagPalette)) } },
            onDismiss = { editingSlot = null },
        )
    }
}

/**
 * Label, color, and the only route to deletion — behind a confirmation,
 * because per-message tags on a retired slot outlive the palette entry.
 * The built-in flag's entry has no deletion: it offers Reset to default in
 * its place, which needs no confirmation, because it changes a name, a
 * color and a position and touches no message.
 */
@Composable
private fun FlagEditorDialog(
    entry: FlagPaletteEntry,
    canReset: Boolean,
    canMakeDefault: Boolean,
    onMakeDefault: () -> Unit,
    onChange: (FlagPaletteEntry) -> Unit,
    onDelete: () -> Unit,
    onReset: () -> Unit,
    onDismiss: () -> Unit,
) {
    val isSystemEntry = FlagPaletteEdits.isSystemEntry(entry.slot)
    var confirmingDelete by rememberSaveable { mutableStateOf(false) }
    // The name field never writes an empty name (see FlagNameField). Read
    // through `seeing` at each composition, so a name that changed by
    // another route (Reset to default below, a pull) shows at once.
    var typedName by remember(entry.slot) { mutableStateOf(FlagNameField.opening(entry.label)) }
    val name = typedName.seeing(entry.label)
    val leave = {
        name.leaving()?.let { onChange(entry.copy(label = it)) }
        onDismiss()
    }
    AlertDialog(
        onDismissRequest = leave,
        title = { Text(stringResource(R.string.flags_edit)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name.text,
                    onValueChange = { value ->
                        val (next, written) = name.typed(value)
                        typedName = next
                        written?.let { onChange(entry.copy(label = it)) }
                    },
                    label = { Text(stringResource(R.string.flags_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.flags_color), style = MaterialTheme.typography.titleSmall)
                ColorSwatches(selectedColor = entry.color, onSelect = { onChange(entry.copy(color = it)) })
                // Dimmed, never hidden, on the flag that is the default
                // already: the dialog keeps its shape whichever flag it
                // opens on.
                TextButton(onClick = onMakeDefault, enabled = canMakeDefault) {
                    Text(stringResource(R.string.flags_make_default))
                }
                if (isSystemEntry) {
                    TextButton(onClick = onReset, enabled = canReset) {
                        Text(stringResource(R.string.flags_reset))
                    }
                    Text(
                        stringResource(R.string.flags_reset_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    TextButton(onClick = { confirmingDelete = true }) {
                        Text(stringResource(R.string.flags_delete), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = leave) { Text(stringResource(R.string.rules_done)) }
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

/**
 * Maps the wire color vocabulary onto the `flag.<name>` tokens, which every
 * client shares. Unknown names — a newer server's vocabulary — render gray
 * but round-trip unchanged; the name is user data and never changes.
 */
@Composable
@ReadOnlyComposable
internal fun flagColor(name: String): Color = ColorTokens.flag(name)
