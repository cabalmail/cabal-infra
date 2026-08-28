package com.cabalmail.android.ui.settings

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.notifications.NewMailSync

/**
 * The new-mail toggle (plan §7.3, push since the FCM phase): turning it on
 * asks for the notification permission on API 33+, schedules the periodic
 * sync, and registers for push where available; off cancels and
 * deregisters.
 */
@Composable
internal fun NotificationsRow(
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
    onPushChange: (Boolean) -> Unit,
) {
    val context = LocalContext.current
    var denied by remember { mutableStateOf(false) }
    val enable = {
        NewMailSync.clearBaseline(context)
        NewMailSync.schedule(context, enabled = true)
        onChange(true)
        onPushChange(true)
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
                onPushChange(false)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !NewMailSync.canPost(context)) {
                permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                enable()
            }
        },
    )
}

/**
 * The push folder opt-in (per device, like the Apple clients): Inbox only,
 * all folders, or an explicit selection. Disabled while notifications are
 * off. The fallback 15-minute check stays Inbox-only regardless — the
 * dialog says so.
 */
@Composable
internal fun PushFoldersRow(
    pushFolders: Set<String>,
    enabled: Boolean,
    folderChoices: List<String>?,
    onLoadFolderChoices: () -> Unit,
    onChange: (Set<String>) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val scope = PushFolderScope.of(pushFolders)
    val summary =
        when (scope) {
            PushFolderScope.InboxOnly -> stringResource(R.string.push_folders_inbox_only)
            PushFolderScope.All -> stringResource(R.string.push_folders_all)
            is PushFolderScope.Custom ->
                pluralStringResource(R.plurals.push_folders_count, scope.folders.size, scope.folders.size)
        }
    ListItem(
        headlineContent = { Text(stringResource(R.string.settings_push_folders)) },
        supportingContent = { Text(summary) },
        modifier =
            Modifier.clickable(enabled = enabled) {
                onLoadFolderChoices()
                open = true
            },
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
        var custom by remember { mutableStateOf(scope is PushFolderScope.Custom) }
        var all by remember { mutableStateOf(scope is PushFolderScope.All) }
        var checked by
            remember {
                mutableStateOf((scope as? PushFolderScope.Custom)?.folders ?: setOf("INBOX"))
            }
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(stringResource(R.string.settings_push_folders)) },
            text = {
                Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                    Text(
                        stringResource(R.string.push_folders_hint),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                    listOf(
                        Triple(stringResource(R.string.push_folders_inbox_only), !all && !custom) {
                            all = false
                            custom = false
                        },
                        Triple(stringResource(R.string.push_folders_all), all) {
                            all = true
                            custom = false
                        },
                        Triple(stringResource(R.string.push_folders_custom), custom) {
                            all = false
                            custom = true
                        },
                    ).forEach { (label, selected, choose) ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .selectable(selected = selected, onClick = choose)
                                    .padding(vertical = 6.dp),
                        ) {
                            RadioButton(selected = selected, onClick = null)
                            Text(label, modifier = Modifier.padding(start = 12.dp))
                        }
                    }
                    if (custom) {
                        val choices =
                            (listOf("INBOX") + (folderChoices ?: checked.sorted())).distinct()
                        choices.forEach { folder ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier =
                                    Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            checked =
                                                if (folder in checked) checked - folder else checked + folder
                                        }.padding(start = 12.dp, top = 2.dp, bottom = 2.dp),
                            ) {
                                Checkbox(
                                    checked = folder in checked,
                                    onCheckedChange = null,
                                )
                                Text(folder, modifier = Modifier.padding(start = 12.dp))
                            }
                        }
                        if (folderChoices == null) {
                            Text(
                                stringResource(R.string.push_folders_loading),
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(start = 12.dp, top = 4.dp),
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        open = false
                        onChange(
                            pushFoldersFor(
                                when {
                                    all -> PushFolderScope.All
                                    custom -> PushFolderScope.Custom(checked)
                                    else -> PushFolderScope.InboxOnly
                                },
                            ),
                        )
                    },
                ) { Text(stringResource(R.string.save)) }
            },
            dismissButton = {
                TextButton(onClick = { open = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}
