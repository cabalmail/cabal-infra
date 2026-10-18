package com.cabalmail.android.ui.admin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.settings.SettingsSectionFooter
import com.cabalmail.android.ui.settings.SettingsSectionHeader
import com.cabalmail.kit.models.PoolUser

/**
 * The administrator's Users screen (auth parity plan, C2), the Users
 * category's detail pane in Settings. Settings lists the category only when
 * the session's token names the `admin` group; the server enforces it either
 * way. Rows open [UserDetailScreen] for the account's actions and domain
 * access.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UsersScreen(
    state: UsersUiState,
    onOpenUser: (String) -> Unit,
    onReload: () -> Unit,
    onDismissError: () -> Unit,
    /** Null when the settings category list is visible alongside. */
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val snackbarHostState = remember { SnackbarHostState() }
    UsersActionErrorSnackbar(state.actionError, snackbarHostState, onDismissError)
    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.users_title)) },
                navigationIcon = { UsersBackButton(onBack) },
                actions = {
                    IconButton(onClick = onReload) {
                        Icon(Icons.Default.Refresh, contentDescription = stringResource(R.string.rules_reload))
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            when {
                state.accessDenied -> AccessDenied()
                state.loading -> Loading()
                state.loadError != null -> LoadError(state.loadError, onReload)
                else -> UsersList(state, onOpenUser)
            }
        }
    }
}

@Composable
private fun UsersList(
    state: UsersUiState,
    onOpenUser: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        if (state.pending.isNotEmpty()) {
            SettingsSectionHeader(stringResource(R.string.users_pending_header))
            state.pending.forEach { UserRow(it, state, onOpenUser) }
            SettingsSectionFooter(stringResource(R.string.users_pending_footer))
        }
        SettingsSectionHeader(stringResource(R.string.users_title))
        state.confirmed.forEach { UserRow(it, state, onOpenUser) }
        SettingsSectionFooter(stringResource(R.string.users_footer))
    }
}

@Composable
private fun UserRow(
    user: PoolUser,
    state: UsersUiState,
    onOpenUser: (String) -> Unit,
) {
    val summary =
        buildList {
            add(if (user.isPending) statusText(user.status) else signInText(user.enabled))
            if (state.isCurrentUser(user.username)) add(stringResource(R.string.users_you))
        }.joinToString(" · ")
    ListItem(
        headlineContent = { Text(user.username) },
        supportingContent = { Text(summary) },
        modifier = Modifier.clickable { onOpenUser(user.username) },
    )
    HorizontalDivider()
}

/** Cognito's status in words. */
@Composable
internal fun statusText(status: String): String =
    when (status) {
        "CONFIRMED" -> stringResource(R.string.users_status_confirmed)
        "UNCONFIRMED" -> stringResource(R.string.users_status_unconfirmed)
        "FORCE_CHANGE_PASSWORD" -> stringResource(R.string.users_status_force_change)
        "RESET_REQUIRED" -> stringResource(R.string.users_status_reset)
        "" -> stringResource(R.string.users_status_unknown)
        else -> status
    }

@Composable
internal fun signInText(enabled: Boolean): String =
    stringResource(if (enabled) R.string.users_enabled else R.string.users_disabled)

/** Shows a failed action once, worded from `strings.xml`, then clears it. */
@Composable
internal fun UsersActionErrorSnackbar(
    error: UsersActionError?,
    host: SnackbarHostState,
    onShown: () -> Unit,
) {
    val text =
        error?.let {
            when (it.action) {
                UsersAction.CONFIRM -> stringResource(R.string.users_error_confirm, it.username, it.detail)
                UsersAction.ENABLE -> stringResource(R.string.users_error_enable, it.username, it.detail)
                UsersAction.DISABLE -> stringResource(R.string.users_error_disable, it.username, it.detail)
                UsersAction.DELETE -> stringResource(R.string.users_error_delete, it.username, it.detail)
                UsersAction.GRANT ->
                    stringResource(R.string.users_error_grant, it.username, it.domain.orEmpty(), it.detail)
                UsersAction.REVOKE ->
                    stringResource(R.string.users_error_revoke, it.username, it.domain.orEmpty(), it.detail)
            }
        }
    LaunchedEffect(text) {
        val message = text ?: return@LaunchedEffect
        host.showSnackbar(message)
        onShown()
    }
}

@Composable
internal fun UsersBackButton(onBack: (() -> Unit)?) {
    if (onBack != null) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
        }
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
            stringResource(R.string.users_loading),
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
            Text(stringResource(R.string.retry))
        }
    }
}

@Composable
private fun AccessDenied() {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Default.Lock, contentDescription = null)
        Text(
            stringResource(R.string.users_denied_title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            stringResource(R.string.users_denied_body),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
