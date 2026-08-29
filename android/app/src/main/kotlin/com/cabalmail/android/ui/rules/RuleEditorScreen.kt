package com.cabalmail.android.ui.rules

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.settings.flagColor
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField
import com.cabalmail.kit.models.normalizeLegacyContinue
import com.cabalmail.kit.rules.RulesValidator
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * Detail form for one mail rule: name, spill-through, conditions, the
 * mutually-exclusive destination, and the independent extras (flag / mark
 * read / forward / reply). Every change goes through [onUpdate], which
 * schedules the view model's debounced whole-set save. Folder pickers offer
 * existing folders only (the plan's "No folder auto-creation"); the one
 * accommodation is the explicit Create Archive Folder button.
 *
 * Spill-through leads the form and gates the destination (truthful
 * Continue, `docs/1.x/rules-composition-and-custom-flags-plan.md` decision
 * 1): a continuing rule passes the message along, so any delivery it makes
 * is a copy — Move and Archive render disabled in place while Continue is
 * on, and turning Continue on converts them to Copy (identical compiled
 * output, so a conversion is a relabel, not a behavior change).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RuleEditorScreen(
    state: RulesUiState,
    ruleId: String,
    onUpdate: (Rule) -> Unit,
    onCreateArchiveFolder: () -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    /** The custom-flag palette; the Flag extra grew into a picker of the
     * classic flag plus these (rules-composition plan, Phase 5). */
    palette: List<FlagPaletteEntry> = emptyList(),
) {
    val rule = state.rules?.firstOrNull { it.id == ruleId }
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(rule?.name?.ifEmpty { stringResource(R.string.rules_untitled) } ?: "") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        if (rule == null) {
            // Deleted from the list (or on another device) while open.
            Box(modifier = Modifier.padding(innerPadding).fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.rules_rule_deleted))
            }
        } else {
            Column(
                modifier =
                    Modifier
                        .padding(innerPadding)
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Inline note shown after Continue-on auto-converts
                // Move/Archive to Copy; cleared when the user picks a
                // destination or turns Continue off.
                var showConversionNote by rememberSaveable(ruleId) { mutableStateOf(false) }
                NameSection(rule, onUpdate)
                ContinueSection(
                    rule = rule,
                    showConversionNote = showConversionNote,
                    onConversionNote = { showConversionNote = it },
                    onUpdate = onUpdate,
                )
                ConditionsSection(rule, onUpdate)
                DestinationSection(
                    state = state,
                    rule = rule,
                    onUpdate = onUpdate,
                    onCreateArchiveFolder = onCreateArchiveFolder,
                    onDestinationPicked = { showConversionNote = false },
                )
                ExtrasSection(rule, palette, onUpdate)
            }
        }
    }
    if (state.conflict) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text(stringResource(R.string.rules_conflict_title)) },
            text = { Text(stringResource(R.string.rules_conflict_body)) },
            confirmButton = {
                TextButton(onClick = {
                    onReload()
                    onBack()
                }) { Text(stringResource(R.string.rules_reload)) }
            },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 12.dp),
    )
}

@Composable
private fun Hint(
    text: String,
    error: Boolean = false,
) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun NameSection(
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    OutlinedTextField(
        value = rule.name,
        onValueChange = { onUpdate(rule.copy(name = it)) },
        label = { Text(stringResource(R.string.rules_name)) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
    )
    ToggleRow(stringResource(R.string.rules_enabled), rule.enabled) {
        onUpdate(rule.copy(enabled = it))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConditionsSection(
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_conditions))
    rule.conditions.forEachIndexed { index, condition ->
        ConditionRow(
            condition = condition,
            onChange = { changed ->
                onUpdate(rule.copy(conditions = rule.conditions.toMutableList().apply { set(index, changed) }))
            },
            onRemove = {
                onUpdate(rule.copy(conditions = rule.conditions.toMutableList().apply { removeAt(index) }))
            },
        )
    }
    if (rule.conditions.size < RulesValidator.MAX_CONDITIONS) {
        TextButton(onClick = { onUpdate(rule.copy(conditions = rule.conditions + RuleCondition())) }) {
            Text(stringResource(R.string.rules_add_condition))
        }
    }
    Hint(
        stringResource(
            if (rule.conditions.isEmpty()) R.string.rules_conditions_empty_hint else R.string.rules_conditions_hint,
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConditionRow(
    condition: RuleCondition,
    onChange: (RuleCondition) -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        var fieldMenuOpen by rememberSaveable { mutableStateOf(false) }
        ExposedDropdownMenuBox(
            expanded = fieldMenuOpen,
            onExpandedChange = { fieldMenuOpen = it },
            modifier = Modifier.weight(0.42f),
        ) {
            OutlinedTextField(
                value = stringResource(condition.field.labelRes()),
                onValueChange = {},
                readOnly = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = fieldMenuOpen) },
                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
            )
            ExposedDropdownMenu(expanded = fieldMenuOpen, onDismissRequest = { fieldMenuOpen = false }) {
                RuleField.entries.forEach { field ->
                    DropdownMenuItem(
                        text = { Text(stringResource(field.labelRes())) },
                        onClick = {
                            fieldMenuOpen = false
                            onChange(condition.copy(field = field))
                        },
                    )
                }
            }
        }
        OutlinedTextField(
            value = condition.value,
            onValueChange = { onChange(condition.copy(value = it)) },
            placeholder = { Text(stringResource(R.string.rules_condition_value_hint)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
            modifier = Modifier.weight(0.58f),
        )
        IconButton(onClick = onRemove) {
            Icon(Icons.Default.Clear, contentDescription = stringResource(R.string.rules_remove_condition))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DestinationSection(
    state: RulesUiState,
    rule: Rule,
    onUpdate: (Rule) -> Unit,
    onCreateArchiveFolder: () -> Unit,
    onDestinationPicked: () -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_destination))
    // Explicit order matching the other clients' segmented control
    // (Move / Copy / Archive / Delete / None), not enum declaration order.
    val actions =
        listOf(RuleAction.MOVE, RuleAction.COPY, RuleAction.ARCHIVE, RuleAction.DELETE, RuleAction.NONE)
    // Decision 1's gate: a continuing rule can only Copy or None. Move and
    // Archive stay visible but disabled because their spill-through
    // compilation *is* Copy; Delete because the engine ignores Continue on
    // Delete.
    val gatedActions = setOf(RuleAction.MOVE, RuleAction.ARCHIVE, RuleAction.DELETE)
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
        actions.forEachIndexed { index, action ->
            SegmentedButton(
                selected = rule.action == action,
                onClick = {
                    onDestinationPicked()
                    onUpdate(rule.copy(action = action))
                },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = actions.size),
                enabled = !(rule.continueToNext && action in gatedActions),
            ) {
                Text(stringResource(action.labelRes()), maxLines = 1)
            }
        }
    }
    if (rule.continueToNext) {
        Hint(stringResource(R.string.rules_continue_gate_hint))
    }
    when (rule.action) {
        RuleAction.MOVE -> MoveFolderPicker(state, rule, onUpdate)
        RuleAction.COPY -> CopyFoldersPicker(state, rule, onUpdate)
        RuleAction.ARCHIVE ->
            if (state.folders != null && !state.hasArchiveFolder) {
                Hint(stringResource(R.string.rules_no_archive_hint))
                OutlinedButton(onClick = onCreateArchiveFolder) {
                    Text(stringResource(R.string.rules_create_archive))
                }
            }
        RuleAction.DELETE -> Hint(stringResource(R.string.rules_delete_hint))
        RuleAction.NONE ->
            Hint(
                stringResource(
                    if (rule.continueToNext) R.string.rules_none_continue_hint else R.string.rules_none_hint,
                ),
            )
    }
    if (RulesValidator.hasNoEffect(rule)) {
        Hint(stringResource(R.string.rules_no_effect_hint), error = true)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MoveFolderPicker(
    state: RulesUiState,
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    val folders = state.folders.orEmpty()
    // A stored target whose folder was deleted stays selectable (and
    // flagged below) instead of silently resetting. An empty folder list
    // usually means the fetch failed — don't cry wolf then.
    val missing = rule.moveFolder.isNotEmpty() && folders.isNotEmpty() && rule.moveFolder !in folders
    ExposedDropdownMenuBox(expanded = menuOpen, onExpandedChange = { menuOpen = it }) {
        OutlinedTextField(
            value =
                when {
                    rule.moveFolder.isEmpty() -> stringResource(R.string.rules_choose_folder)
                    missing -> stringResource(R.string.rules_folder_missing, rule.moveFolder)
                    else -> rule.moveFolder
                },
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.rules_move_folder)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menuOpen) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            folders.forEach { folder ->
                DropdownMenuItem(
                    text = { Text(folder) },
                    onClick = {
                        menuOpen = false
                        onUpdate(rule.copy(moveFolder = folder))
                    },
                )
            }
        }
    }
    if (missing) {
        Hint(stringResource(R.string.rules_folder_missing_hint), error = true)
    }
}

@Composable
private fun CopyFoldersPicker(
    state: RulesUiState,
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    var dialogOpen by rememberSaveable { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(stringResource(R.string.rules_copy_folders)) },
        supportingContent = {
            Text(
                if (rule.copyFolders.isEmpty()) {
                    stringResource(R.string.rules_choose_folders)
                } else {
                    rule.copyFolders.joinToString(", ")
                },
                maxLines = 2,
            )
        },
        modifier = Modifier.fillMaxWidth(),
        trailingContent = {
            TextButton(onClick = { dialogOpen = true }) { Text(stringResource(R.string.rules_choose_folders)) }
        },
    )
    if (dialogOpen) {
        AlertDialog(
            onDismissRequest = { dialogOpen = false },
            title = { Text(stringResource(R.string.rules_copy_folders)) },
            text = {
                Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                    state.folders.orEmpty().forEach { folder ->
                        val selected = folder in rule.copyFolders
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Checkbox(
                                checked = selected,
                                onCheckedChange = { checked ->
                                    val next =
                                        if (checked) rule.copyFolders + folder else rule.copyFolders - folder
                                    onUpdate(rule.copy(copyFolders = next))
                                },
                                enabled = selected || rule.copyFolders.size < RulesValidator.MAX_COPY_FOLDERS,
                            )
                            Text(folder)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { dialogOpen = false }) { Text(stringResource(R.string.rules_done)) }
            },
        )
    }
}

@Composable
private fun ExtrasSection(
    rule: Rule,
    palette: List<FlagPaletteEntry>,
    onUpdate: (Rule) -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_extras))
    val locked = rule.action == RuleAction.DELETE
    ToggleRow(stringResource(R.string.rules_flag), rule.flag, enabled = !locked) {
        onUpdate(rule.copy(flag = it))
    }
    // One toggle per enabled palette entry, plus any slot this rule already
    // sets whose entry is disabled or deleted — the compiler skips the rule
    // while such a slot remains (flag_not_in_palette), so the stray toggle
    // is the affordance for clearing it, labelled by slot id when gone.
    pickerSlots(palette, rule.flags).forEach { slot ->
        val entry = palette.firstOrNull { it.slot == slot }
        FlagToggleRow(
            label = entry?.label ?: slot,
            color = flagColor(entry?.color ?: ""),
            checked = slot in rule.flags,
            enabled = !locked,
        ) { on ->
            val next = if (on) rule.flags + slot else rule.flags - slot
            onUpdate(rule.copy(flags = next))
        }
    }
    ToggleRow(stringResource(R.string.rules_mark_read), rule.markRead, enabled = !locked) {
        onUpdate(rule.copy(markRead = it))
    }
    if (!locked) {
        ForwardEditor(rule, onUpdate)
    }
    ToggleRow(stringResource(R.string.rules_reply), rule.reply, enabled = !locked) {
        onUpdate(rule.copy(reply = it))
    }
    if (rule.reply && !locked) {
        ReplyBodyEditor(rule, onUpdate)
    }
    if (locked) {
        Hint(stringResource(R.string.rules_extras_delete_hint))
    } else if (rule.reply) {
        Hint(stringResource(R.string.rules_reply_hint))
    }
}

/** Addresses land in the rule only when they pass the same shape check the
 * server applies, so the server's strip-at-PUT path stays unreachable. */
@Composable
private fun ForwardEditor(
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    rule.forward.forEach { address ->
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(address, modifier = Modifier.weight(1f))
            IconButton(onClick = { onUpdate(rule.copy(forward = rule.forward - address)) }) {
                Icon(
                    Icons.Default.Clear,
                    contentDescription = stringResource(R.string.rules_forward_remove, address),
                )
            }
        }
    }
    if (rule.forward.size < RulesValidator.MAX_FORWARDS) {
        var newAddress by rememberSaveable { mutableStateOf("") }
        val trimmed = newAddress.trim()
        val canAdd = RulesValidator.isValidForwardAddress(trimmed) && trimmed !in rule.forward
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = newAddress,
                onValueChange = { newAddress = it },
                placeholder = { Text(stringResource(R.string.rules_forward_hint)) },
                singleLine = true,
                keyboardOptions =
                    KeyboardOptions(
                        keyboardType = KeyboardType.Email,
                        capitalization = KeyboardCapitalization.None,
                    ),
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = {
                    onUpdate(rule.copy(forward = rule.forward + trimmed))
                    newAddress = ""
                },
                enabled = canAdd,
            ) {
                Text(stringResource(R.string.rules_forward_add))
            }
        }
    }
}

@Composable
private fun ReplyBodyEditor(
    rule: Rule,
    onUpdate: (Rule) -> Unit,
) {
    OutlinedTextField(
        value = rule.replyBody,
        onValueChange = { onUpdate(rule.copy(replyBody = it)) },
        minLines = 4,
        modifier = Modifier.fillMaxWidth(),
    )
    val count = rule.replyBody.codePointCount(0, rule.replyBody.length)
    Hint(
        stringResource(R.string.rules_reply_counter, count, RulesValidator.MAX_REPLY_BODY_LENGTH),
        error = count > RulesValidator.MAX_REPLY_BODY_LENGTH,
    )
    if (rule.replyBody.isEmpty()) {
        Hint(stringResource(R.string.rules_reply_body_required), error = true)
    }
}

@Composable
private fun ContinueSection(
    rule: Rule,
    showConversionNote: Boolean,
    onConversionNote: (Boolean) -> Unit,
    onUpdate: (Rule) -> Unit,
) {
    val locked = rule.action == RuleAction.DELETE
    ToggleRow(stringResource(R.string.rules_continue), rule.continueToNext, enabled = !locked) { isOn ->
        // Turning Continue on while Move/Archive is selected converts the
        // destination to Copy, carrying the folder — safe, not a guess: the
        // compiled output is identical (decision 1).
        onConversionNote(
            isOn && (rule.action == RuleAction.MOVE || rule.action == RuleAction.ARCHIVE),
        )
        onUpdate(rule.copy(continueToNext = isOn).normalizeLegacyContinue())
    }
    Hint(
        stringResource(if (locked) R.string.rules_continue_delete_hint else R.string.rules_continue_hint),
    )
    if (showConversionNote) {
        Hint(stringResource(R.string.rules_converted_to_copy))
    }
}

@Composable
private fun ToggleRow(
    title: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}

/** The slots the picker offers: enabled palette entries in palette order,
 * then stray already-set slots (see ExtrasSection). Pure, tested. */
internal fun pickerSlots(
    palette: List<FlagPaletteEntry>,
    ruleFlags: List<String>,
): List<String> {
    val offered = palette.filter { it.enabled }.map { it.slot }
    val stray = FlagPalette.SLOTS.filter { it in ruleFlags && it !in offered }
    return offered + stray
}

@Composable
private fun FlagToggleRow(
    label: String,
    color: Color,
    checked: Boolean,
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier =
                Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(color),
        )
        Spacer(Modifier.width(8.dp))
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}

private fun RuleField.labelRes(): Int =
    when (this) {
        RuleField.FROM -> R.string.rules_field_from
        RuleField.TO -> R.string.rules_field_to
        RuleField.CC -> R.string.rules_field_cc
        RuleField.SUBJECT -> R.string.rules_field_subject
        RuleField.BODY -> R.string.rules_field_body
    }

private fun RuleAction.labelRes(): Int =
    when (this) {
        RuleAction.MOVE -> R.string.rules_action_move
        RuleAction.COPY -> R.string.rules_action_copy
        RuleAction.ARCHIVE -> R.string.rules_action_archive
        RuleAction.DELETE -> R.string.rules_action_delete
        RuleAction.NONE -> R.string.rules_action_none
    }
