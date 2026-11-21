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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.Rule

/**
 * What a rule's row does, each taking the rule's id. The mail list and the
 * feed list each hand the screen one of these, so both draw the one row.
 */
class RuleRowActions(
    val onOpen: (String) -> Unit,
    val onSetEnabled: (String, Boolean) -> Unit,
    val onMove: (String, Int) -> Unit,
    val onDuplicate: (String) -> Unit,
    val onDelete: (String) -> Unit,
)

/**
 * The rules master list (`docs/1.x/user-mail-rules-plan.md`, Phase 4b, and
 * `docs/1.x/cross-media-ux-plan.md`, Phase 4): the mail rules under "Email
 * messages" and, after them, the feed rules under "Feed items". Each list
 * has enable, reorder (row-menu Move up / Move down — the Compose idiom
 * here, not a transplant of the iOS drag grip), duplicate and delete; the
 * top bar's Add makes a rule of either kind; and the empty state offers the
 * quick-start templates. Rows open [RuleEditorScreen] or
 * [FeedRuleEditorScreen].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RulesScreen(
    state: RulesUiState,
    /** Adds a mail rule: the template given, or a blank one for null. */
    onAdd: (Rule?) -> Unit,
    mailRows: RuleRowActions,
    /** Adds a feed rule: the template given, or a blank one for null. */
    onAddFeed: (FeedRule?) -> Unit,
    feedRows: RuleRowActions,
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
                    AddRuleMenu(
                        canAddMail = !RuleListEdits.mail.isFull(state.rules.orEmpty()),
                        // No feed rule can be added before the lists load:
                        // the view model has no list to add it to.
                        canAddFeed = state.feedRules != null && !RuleListEdits.feed.isFull(state.feedRules),
                        onAddMail = { onAdd(null) },
                        onAddFeed = { onAddFeed(null) },
                    )
                },
            )
        },
        bottomBar = { RulesSaveBar(state.saveState, onRetrySave) },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            val rules = state.rules
            val feedRules = state.feedRules.orEmpty()
            when {
                state.loading || (rules == null && state.loadError == null) -> Loading()
                state.loadError != null -> LoadError(state.loadError, onReload)
                rules.isNullOrEmpty() && feedRules.isEmpty() -> RulesEmptyState(onAdd, onAddFeed)
                else -> RulesList(state, rules.orEmpty(), feedRules, mailRows, feedRows)
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

/**
 * The top bar's Add. With two lists it opens a menu of the two kinds of
 * rule; a kind whose list is at the server's cap is left out, and with
 * neither to offer the button goes, as it did at the mail cap.
 */
@Composable
private fun AddRuleMenu(
    canAddMail: Boolean,
    canAddFeed: Boolean,
    onAddMail: () -> Unit,
    onAddFeed: () -> Unit,
) {
    if (!canAddMail && !canAddFeed) {
        return
    }
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Default.Add, contentDescription = stringResource(R.string.rules_add))
    }
    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
        if (canAddMail) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.rules_add_mail)) },
                onClick = {
                    open = false
                    onAddMail()
                },
            )
        }
        if (canAddFeed) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.rules_add_feed)) },
                onClick = {
                    open = false
                    onAddFeed()
                },
            )
        }
    }
}

@Composable
private fun RulesList(
    state: RulesUiState,
    rules: List<Rule>,
    feedRules: List<FeedRule>,
    mailRows: RuleRowActions,
    feedRows: RuleRowActions,
) {
    LazyColumn(modifier = Modifier.fillMaxSize()) {
        item(key = "header:mail") { SectionHeader(stringResource(R.string.rules_section_mail)) }
        if (rules.isEmpty()) {
            item(key = "empty:mail") { SectionNote(stringResource(R.string.rules_section_mail_empty)) }
        }
        // A rule's id is unique across both lists on the server; the prefix
        // keeps the keys apart for a rule minted here and not yet saved.
        items(rules, key = { "mail:" + it.id }) { rule ->
            RuleRow(
                row =
                    RuleRowContent(
                        id = rule.id,
                        name = rule.name,
                        summary = describeRule(rule),
                        enabled = rule.enabled,
                        first = rule.id == rules.first().id,
                        last = rule.id == rules.last().id,
                    ),
                actions = mailRows,
            )
            HorizontalDivider()
        }
        item(key = "footer:mail") { SectionNote(stringResource(R.string.rules_list_footer)) }
        item(key = "header:feed") { SectionHeader(stringResource(R.string.rules_section_feed)) }
        if (feedRules.isEmpty()) {
            item(key = "empty:feed") { SectionNote(stringResource(R.string.rules_section_feed_empty)) }
        }
        items(feedRules, key = { "feed:" + it.id }) { rule ->
            RuleRow(
                row =
                    RuleRowContent(
                        id = rule.id,
                        name = rule.name,
                        summary = describeFeedRule(rule, state.subscriptionTitle(rule.feedSubscriptionId)),
                        enabled = rule.enabled,
                        first = rule.id == feedRules.first().id,
                        last = rule.id == feedRules.last().id,
                        editable = rule.isEditable,
                    ),
                actions = feedRows,
            )
            HorizontalDivider()
        }
        item(key = "footer:feed") { SectionNote(stringResource(R.string.rules_feed_list_footer)) }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun SectionNote(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
    )
}

/** What a rule's row draws, of either kind of rule. */
private class RuleRowContent(
    val id: String,
    val name: String,
    val summary: String,
    val enabled: Boolean,
    val first: Boolean,
    val last: Boolean,
    /**
     * False for a feed rule this build cannot render: its switch is locked
     * and it cannot be duplicated, since either would save a rewritten copy
     * of a rule this build cannot express. It can still be moved, deleted
     * and opened (its editor says why it is read-only).
     */
    val editable: Boolean = true,
)

@Composable
private fun RuleRow(
    row: RuleRowContent,
    actions: RuleRowActions,
) {
    var menuOpen by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = {
            Text(row.name.ifEmpty { stringResource(R.string.rules_untitled) })
        },
        supportingContent = {
            Text(row.summary, maxLines = 2)
        },
        leadingContent = {
            Switch(
                checked = row.enabled,
                onCheckedChange = { actions.onSetEnabled(row.id, it) },
                enabled = row.editable,
            )
        },
        trailingContent = {
            Row {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.rules_row_menu))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (!row.first) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rules_move_up)) },
                            onClick = {
                                menuOpen = false
                                actions.onMove(row.id, -1)
                            },
                        )
                    }
                    if (!row.last) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rules_move_down)) },
                            onClick = {
                                menuOpen = false
                                actions.onMove(row.id, 1)
                            },
                        )
                    }
                    if (row.editable) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.rules_duplicate)) },
                            onClick = {
                                menuOpen = false
                                actions.onDuplicate(row.id)
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.rules_delete)) },
                        onClick = {
                            menuOpen = false
                            actions.onDelete(row.id)
                        },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = { actions.onOpen(row.id) }),
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

/** First-run screen, shown while both lists are empty: the plan's three mail
 * templates and the feed one, plus a blank rule of either kind. */
@Composable
private fun RulesEmptyState(
    onAdd: (Rule?) -> Unit,
    onAddFeed: (FeedRule?) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
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
        TemplateButton(R.string.rules_template_feed_flag, R.string.rules_template_feed_flag_hint) {
            onAddFeed(RuleTemplates.flagMatchingItems())
        }
        TextButton(onClick = { onAdd(null) }) {
            Text(stringResource(R.string.rules_blank_rule))
        }
        TextButton(onClick = { onAddFeed(null) }) {
            Text(stringResource(R.string.rules_blank_feed_rule))
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
