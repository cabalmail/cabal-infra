package com.cabalmail.android.ui.rules

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.rules.RulesValidator

/**
 * Mail-rules master list (`docs/1.x/user-mail-rules-plan.md`, Phase 4b):
 * enable, reorder (row-menu Move up / Move down — the Compose idiom here,
 * not a transplant of the iOS drag grip), add, duplicate, delete, and the
 * empty state's quick-start templates. Rows open [RuleEditorScreen].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RulesScreen(
    state: RulesUiState,
    onAdd: (Rule?) -> Unit,
    onOpenRule: (String) -> Unit,
    onSetEnabled: (String, Boolean) -> Unit,
    onMove: (String, Int) -> Unit,
    onDuplicate: (String) -> Unit,
    onDelete: (String) -> Unit,
    onReload: () -> Unit,
    onRetrySave: () -> Unit,
    /** Null when the settings category list is visible alongside. */
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.rules_title)) },
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
                actions = {
                    if (state.rules.orEmpty().size < RulesValidator.MAX_RULES) {
                        IconButton(onClick = { onAdd(null) }) {
                            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.rules_add))
                        }
                    }
                },
            )
        },
        bottomBar = { RulesSaveBar(state.saveState, onRetrySave) },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            val rules = state.rules
            when {
                state.loading || (rules == null && state.loadError == null) -> Loading()
                state.loadError != null -> LoadError(state.loadError, onReload)
                rules.isNullOrEmpty() -> RulesEmptyState(onAdd)
                else -> RulesList(rules, onOpenRule, onSetEnabled, onMove, onDuplicate, onDelete)
            }
        }
    }
    if (state.conflict) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text(stringResource(R.string.rules_conflict_title)) },
            text = { Text(stringResource(R.string.rules_conflict_body)) },
            confirmButton = {
                TextButton(onClick = onReload) { Text(stringResource(R.string.rules_reload)) }
            },
        )
    }
}

@Composable
private fun Loading() {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
        Text(
            stringResource(R.string.rules_loading),
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 12.dp),
        )
    }
}

@Composable
private fun LoadError(
    message: String,
    onReload: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(message, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
        OutlinedButton(onClick = onReload, modifier = Modifier.padding(top = 12.dp)) {
            Text(stringResource(R.string.rules_retry))
        }
    }
}

@Composable
private fun RulesList(
    rules: List<Rule>,
    onOpenRule: (String) -> Unit,
    onSetEnabled: (String, Boolean) -> Unit,
    onMove: (String, Int) -> Unit,
    onDuplicate: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    LazyColumn(modifier = Modifier.fillMaxSize()) {
        items(rules, key = { it.id }) { rule ->
            RuleRow(
                rule = rule,
                first = rule.id == rules.first().id,
                last = rule.id == rules.last().id,
                onOpen = { onOpenRule(rule.id) },
                onSetEnabled = { onSetEnabled(rule.id, it) },
                onMove = { delta -> onMove(rule.id, delta) },
                onDuplicate = { onDuplicate(rule.id) },
                onDelete = { onDelete(rule.id) },
            )
            HorizontalDivider()
        }
        item {
            Text(
                stringResource(R.string.rules_list_footer),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
        }
    }
}

@Composable
private fun RuleRow(
    rule: Rule,
    first: Boolean,
    last: Boolean,
    onOpen: () -> Unit,
    onSetEnabled: (Boolean) -> Unit,
    onMove: (Int) -> Unit,
    onDuplicate: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = {
            Text(rule.name.ifEmpty { stringResource(R.string.rules_untitled) })
        },
        supportingContent = {
            Text(describeRule(rule), maxLines = 2)
        },
        leadingContent = {
            Switch(checked = rule.enabled, onCheckedChange = onSetEnabled)
        },
        trailingContent = {
            Row {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.rules_row_menu))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (!first) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rules_move_up)) },
                            onClick = {
                                menuOpen = false
                                onMove(-1)
                            },
                        )
                    }
                    if (!last) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rules_move_down)) },
                            onClick = {
                                menuOpen = false
                                onMove(1)
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.rules_duplicate)) },
                        onClick = {
                            menuOpen = false
                            onDuplicate()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.rules_delete)) },
                        onClick = {
                            menuOpen = false
                            onDelete()
                        },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = onOpen),
    )
}

/** The auto-save indicator: idle / saving / saved / error with Retry. */
@Composable
private fun RulesSaveBar(
    saveState: RulesSaveState,
    onRetry: () -> Unit,
) {
    if (saveState == RulesSaveState.Idle) {
        return
    }
    Surface(tonalElevation = 2.dp) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            when (saveState) {
                RulesSaveState.Idle -> Unit
                RulesSaveState.Saving -> {
                    CircularProgressIndicator(modifier = Modifier.padding(2.dp).size(16.dp))
                    Text(stringResource(R.string.rules_saving), style = MaterialTheme.typography.bodySmall)
                }
                RulesSaveState.Saved ->
                    Text(stringResource(R.string.rules_saved), style = MaterialTheme.typography.bodySmall)
                is RulesSaveState.Error -> {
                    Text(
                        saveState.message,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onRetry) { Text(stringResource(R.string.rules_retry)) }
                }
            }
        }
    }
}

/** First-run screen: the plan's three starter templates plus a blank rule. */
@Composable
private fun RulesEmptyState(onAdd: (Rule?) -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
    ) {
        Text(stringResource(R.string.rules_empty_title), style = MaterialTheme.typography.titleLarge)
        Text(
            stringResource(R.string.rules_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        TemplateButton(R.string.rules_template_receipts, R.string.rules_template_receipts_hint) {
            onAdd(RuleTemplates.fileReceipts())
        }
        TemplateButton(R.string.rules_template_newsletter, R.string.rules_template_newsletter_hint) {
            onAdd(RuleTemplates.muteNewsletter())
        }
        TemplateButton(R.string.rules_template_vacation, R.string.rules_template_vacation_hint) {
            onAdd(RuleTemplates.vacationReply())
        }
        TextButton(onClick = { onAdd(null) }) {
            Text(stringResource(R.string.rules_blank_rule))
        }
    }
}

@Composable
private fun TemplateButton(
    titleRes: Int,
    hintRes: Int,
    onClick: () -> Unit,
) {
    OutlinedButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            Text(stringResource(titleRes))
            Text(
                stringResource(hintRes),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
