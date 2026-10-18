package com.cabalmail.android.ui.admin

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.settings.SettingsSectionFooter
import com.cabalmail.android.ui.settings.SettingsSectionHeader
import com.cabalmail.android.ui.settings.ToggleRow
import com.cabalmail.kit.models.PoolUser
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * One account, as an administrator manages it: its status, the actions it
 * allows (confirm, enable or disable, delete), and which mail domains it may
 * create addresses on. Opened from [UsersScreen]; shares its view model.
 *
 * The signed-in administrator's own account offers no Disable or Delete: the
 * server refuses deleting it, and disabling it would sign them out for good.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UserDetailScreen(
    state: UsersUiState,
    username: String,
    onConfirm: (String) -> Unit,
    onSetEnabled: (String, Boolean) -> Unit,
    onDelete: (String) -> Unit,
    onSetAccess: (String, String, Boolean) -> Unit,
    onDismissError: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbarHostState = remember { SnackbarHostState() }
    UsersActionErrorSnackbar(state.actionError, snackbarHostState, onDismissError)
    var confirmingDelete by rememberSaveable { mutableStateOf(false) }
    val user = state.user(username)
    // Deleted (here or elsewhere) once the list has loaded: nothing left to show.
    LaunchedEffect(user == null, state.loading) {
        if (user == null && !state.loading) onBack()
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text(username) },
                navigationIcon = { UsersBackButton(onBack) },
            )
        },
    ) { innerPadding ->
        Box(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            if (user != null) {
                UserDetail(state, user, onConfirm, onSetEnabled, onSetAccess) { confirmingDelete = true }
            } else if (!state.loading) {
                Text(
                    stringResource(R.string.users_gone),
                    modifier = Modifier.align(Alignment.Center),
                )
            }
        }
    }

    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text(stringResource(R.string.users_delete_confirm_title, username)) },
            text = { Text(stringResource(R.string.users_delete_confirm_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingDelete = false
                        onDelete(username)
                    },
                ) {
                    Text(stringResource(R.string.users_delete_confirm), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun UserDetail(
    state: UsersUiState,
    user: PoolUser,
    onConfirm: (String) -> Unit,
    onSetEnabled: (String, Boolean) -> Unit,
    onSetAccess: (String, String, Boolean) -> Unit,
    onRequestDelete: () -> Unit,
) {
    val busy = user.username in state.busy
    val isSelf = state.isCurrentUser(user.username)
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        ListItem(
            headlineContent = { Text(statusText(user.status)) },
            supportingContent = { Text(stringResource(R.string.users_status)) },
        )
        ListItem(
            headlineContent = { Text(signInText(user.enabled)) },
            supportingContent = { Text(stringResource(R.string.users_sign_in)) },
        )
        user.created?.let { created ->
            val date =
                DateTimeFormatter
                    .ofLocalizedDate(FormatStyle.MEDIUM)
                    .withZone(ZoneId.systemDefault())
                    .format(created)
            ListItem(
                headlineContent = { Text(date) },
                supportingContent = { Text(stringResource(R.string.users_created)) },
            )
        }
        user.osid?.let { osid ->
            ListItem(
                headlineContent = { Text(osid) },
                supportingContent = { Text(stringResource(R.string.users_osid)) },
            )
        }

        if (user.isPending) {
            TextButton(onClick = { onConfirm(user.username) }, enabled = !busy, modifier = actionPadding) {
                Text(stringResource(R.string.users_confirm))
            }
        } else {
            TextButton(
                onClick = { onSetEnabled(user.username, !user.enabled) },
                enabled = !busy && !isSelf,
                modifier = actionPadding,
            ) {
                Text(stringResource(if (user.enabled) R.string.users_disable else R.string.users_enable))
            }
        }
        TextButton(onClick = onRequestDelete, enabled = !busy && !isSelf, modifier = actionPadding) {
            Text(
                stringResource(R.string.users_delete),
                color =
                    if (!busy &&
                        !isSelf
                    ) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
            )
        }
        if (isSelf) {
            SettingsSectionFooter(stringResource(R.string.users_self_footer))
        }

        SettingsSectionHeader(stringResource(R.string.users_domain_header))
        state.domains.forEach { domain ->
            ToggleRow(
                title = domain,
                checked = state.hasAccess(user.username, domain),
                onChange = { allowed -> onSetAccess(user.username, domain, allowed) },
            )
        }
        SettingsSectionFooter(stringResource(R.string.users_domain_footer, user.username))
    }
}

private val actionPadding = Modifier.padding(horizontal = 8.dp)
