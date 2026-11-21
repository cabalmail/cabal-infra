package com.cabalmail.android.ui.rules

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.settings.flagColor
import com.cabalmail.kit.models.FeedRule
import com.cabalmail.kit.models.FeedRuleCondition
import com.cabalmail.kit.models.FeedRuleField
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.rules.RulesValidator
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * Detail form for one feed rule (`docs/1.x/cross-media-ux-plan.md`, Phase
 * 4): name, the feed it applies to, the ANDed text conditions, and the
 * marks it makes (flags and Mark as read). Every change goes through
 * [onUpdate], which schedules the view model's debounced whole-set save.
 *
 * A feed rule is a mail rule with the filing taken out, so this is
 * [RuleEditorScreen] without Continue, Destination, Forward and Reply.
 * Nothing is filed, which is also why there is no order to explain: every
 * enabled rule that matches a new item applies to it.
 *
 * A rule carrying a condition field this build does not know is shown
 * read-only, with what it uses: the view model refuses an edit to it, so
 * controls here would only look as if they worked.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedRuleEditorScreen(
    state: RulesUiState,
    ruleId: String,
    onUpdate: (FeedRule) -> Unit,
    onReload: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    /** The flag list of Settings > Flags, which the rule's flag toggles follow. */
    palette: List<FlagPaletteEntry> = emptyList(),
) {
    val rule = state.feedRules?.firstOrNull { it.id == ruleId }
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
                if (rule.isEditable) {
                    FeedNameSection(rule, onUpdate)
                    FeedScopeSection(rule, state.subscriptions, onUpdate)
                    FeedConditionsSection(rule, onUpdate)
                    FeedActionsSection(rule, palette, onUpdate)
                } else {
                    Hint(
                        stringResource(R.string.rules_feed_opaque_hint, rule.unknownFields.joinToString(", ")),
                    )
                }
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
private fun FeedNameSection(
    rule: FeedRule,
    onUpdate: (FeedRule) -> Unit,
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

/**
 * The feed the rule is limited to. On the wire this is a condition (`feed`,
 * holding a subscription id), but it is not a "contains" test: the server
 * matches it exactly and allows one to a rule. So the editor shows it as
 * the rule's scope, a picker of its own, and [FeedRule.withFeed] keeps it
 * to one condition.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedScopeSection(
    rule: FeedRule,
    subscriptions: List<RssSubscription>?,
    onUpdate: (FeedRule) -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_feed))
    val stored = rule.feedSubscriptionId
    val unlisted = unlistedFeedLabel(rule, subscriptions)
    val selected =
        when {
            stored == null -> stringResource(R.string.rules_feed_all)
            unlisted != null -> stringResource(unlisted)
            else -> subscriptions?.firstOrNull { it.subscriptionId == stored }?.displayTitle.orEmpty()
        }
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = menuOpen, onExpandedChange = { menuOpen = it }) {
        OutlinedTextField(
            value = selected,
            onValueChange = {},
            readOnly = true,
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menuOpen) },
            modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.rules_feed_all)) },
                onClick = {
                    menuOpen = false
                    onUpdate(rule.withFeed(null))
                },
            )
            // A stored feed this device does not list stays in the menu, so
            // opening the menu and closing it again cannot lose it.
            if (stored != null && unlisted != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(unlisted)) },
                    onClick = { menuOpen = false },
                )
            }
            subscriptions.orEmpty().forEach { subscription ->
                DropdownMenuItem(
                    text = { Text(subscription.displayTitle) },
                    onClick = {
                        menuOpen = false
                        onUpdate(rule.withFeed(subscription.subscriptionId))
                    },
                )
            }
        }
    }
    Hint(
        stringResource(feedScopeHint(rule, subscriptions)),
        error = unlisted == R.string.rules_feed_unsubscribed,
    )
}

/**
 * The ANDed text conditions: a field picker and a contains-value field. The
 * rule's `feed` condition is in the same list on the wire and is not a row
 * here; [FeedScopeSection] owns it.
 */
@Composable
private fun FeedConditionsSection(
    rule: FeedRule,
    onUpdate: (FeedRule) -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_conditions))
    val rows = rule.textConditions
    rows.forEachIndexed { index, condition ->
        FeedConditionRow(
            condition = condition,
            onChange = { changed ->
                onUpdate(rule.withTextConditions(rows.toMutableList().apply { set(index, changed) }))
            },
            onRemove = {
                onUpdate(rule.withTextConditions(rows.toMutableList().apply { removeAt(index) }))
            },
        )
    }
    // The server's cap counts the feed condition too.
    if (rule.conditions.size < RulesValidator.MAX_CONDITIONS) {
        TextButton(onClick = { onUpdate(rule.withTextConditions(rows + FeedRuleCondition())) }) {
            Text(stringResource(R.string.rules_add_condition))
        }
    }
    Hint(stringResource(feedConditionsHint(rule)))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedConditionRow(
    condition: FeedRuleCondition,
    onChange: (FeedRuleCondition) -> Unit,
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
                modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
            )
            ExposedDropdownMenu(expanded = fieldMenuOpen, onDismissRequest = { fieldMenuOpen = false }) {
                FeedRuleField.TEXT.forEach { field ->
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
        // A value is a literal substring, so nothing may rewrite it, as for
        // a mail rule's (#2038). Title, Author and Summary are free text.
        WithoutImeRewrites(holdsAddresses = false) {
            OutlinedTextField(
                value = condition.value,
                onValueChange = { onChange(condition.copy(value = it)) },
                placeholder = { Text(stringResource(R.string.rules_condition_value_hint)) },
                singleLine = true,
                keyboardOptions = ruleConditionKeyboardOptions(holdsAddresses = false),
                modifier = Modifier.weight(0.58f),
            )
        }
        IconButton(onClick = onRemove) {
            Icon(Icons.Default.Clear, contentDescription = stringResource(R.string.rules_remove_condition))
        }
    }
}

/**
 * The marks a feed rule makes: the flags, listed as the mail editor lists
 * them, and Mark as read. They are all a feed rule can do.
 */
@Composable
private fun FeedActionsSection(
    rule: FeedRule,
    palette: List<FlagPaletteEntry>,
    onUpdate: (FeedRule) -> Unit,
) {
    SectionLabel(stringResource(R.string.rules_feed_actions))
    ruleFlagRows(palette, rule.flag, rule.flags).forEach { row ->
        FlagToggleRow(
            label = row.label,
            color = flagColor(row.color),
            checked = row.isOn,
            enabled = true,
        ) { on ->
            onUpdate(rule.settingFlag(row.slot, on))
        }
    }
    ToggleRow(stringResource(R.string.rules_mark_read), rule.markRead) {
        onUpdate(rule.copy(markRead = it))
    }
    val hasDeletedFlag = strayFlagSlots(palette, rule.flags).isNotEmpty()
    Hint(stringResource(feedActionsHint(rule, hasDeletedFlag)), error = hasDeletedFlag)
}

private fun FeedRuleField.labelRes(): Int =
    when (this) {
        FeedRuleField.AUTHOR -> R.string.rules_field_author
        FeedRuleField.SUMMARY -> R.string.rules_field_summary
        else -> R.string.rules_field_title
    }
