package com.cabalmail.android.ui.addresses

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.compose.NewAddressSheet
import com.cabalmail.kit.models.Address

/**
 * The Addresses screen (plan §6.1): the user's addresses with favorites
 * first, a star toggle, swipe-to-revoke and a long-press menu (both behind
 * a confirmation), pull-to-refresh, and a "Request new" FAB that reuses the
 * compose picker's creation sheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddressesScreen(
    state: AddressesUiState,
    viewModel: AddressesViewModel,
    /** Null when hosted as a top-level destination (no back arrow). */
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(state.error) {
        val message = state.error ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(message)
        viewModel.clearError()
    }
    var showCreate by remember { mutableStateOf(false) }
    var confirmingRevoke by remember { mutableStateOf<Address?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.addresses_title)) },
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
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    viewModel.loadMintableDomains()
                    showCreate = true
                },
            ) {
                Icon(Icons.Default.Add, contentDescription = stringResource(R.string.addresses_request_new))
            }
        },
    ) { innerPadding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier.padding(innerPadding).fillMaxSize(),
        ) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                val addresses = state.addresses.orEmpty()
                if (state.addresses != null && addresses.isEmpty()) {
                    item {
                        Text(
                            text = stringResource(R.string.addresses_empty),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                }
                items(addresses, key = { it.address }) { address ->
                    AddressRow(
                        address = address,
                        busy = address.address in state.busy,
                        menuOpen = menuFor == address.address,
                        onToggleFavorite = { viewModel.setFavorite(address, !address.favorite) },
                        onRevoke = { confirmingRevoke = address },
                        onLongPress = { menuFor = address.address },
                        onDismissMenu = { menuFor = null },
                    )
                    HorizontalDivider()
                }
            }
        }
    }

    if (showCreate) {
        NewAddressSheet(
            domains = state.mintableDomains,
            creating = state.creating,
            error = state.createError,
            onCreate = { username, subdomain, tld, comment ->
                viewModel.create(username, subdomain, tld, comment) { showCreate = false }
            },
            onDismiss = { showCreate = false },
        )
    }

    confirmingRevoke?.let { address ->
        AlertDialog(
            onDismissRequest = { confirmingRevoke = null },
            title = { Text(stringResource(R.string.addresses_revoke_confirm_title)) },
            text = { Text(stringResource(R.string.addresses_revoke_confirm_body, address.address)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingRevoke = null
                        viewModel.revoke(address)
                    },
                ) {
                    Text(stringResource(R.string.addresses_revoke), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingRevoke = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun AddressRow(
    address: Address,
    busy: Boolean,
    menuOpen: Boolean,
    onToggleFavorite: () -> Unit,
    onRevoke: () -> Unit,
    onLongPress: () -> Unit,
    onDismissMenu: () -> Unit,
) {
    val dismissState =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                if (value == SwipeToDismissBoxValue.EndToStart) {
                    onRevoke()
                }
                // Never actually dismiss: the confirmation dialog decides.
                false
            },
        )
    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                contentAlignment = Alignment.CenterEnd,
                modifier =
                    Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.errorContainer)
                        .padding(horizontal = 24.dp),
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = stringResource(R.string.addresses_revoke),
                    tint = MaterialTheme.colorScheme.onErrorContainer,
                )
            }
        },
    ) {
        Box(modifier = Modifier.background(MaterialTheme.colorScheme.surface)) {
            ListItem(
                headlineContent = { Text(address.address) },
                supportingContent =
                    if (address.comment.isNotBlank() || address.suspended) {
                        {
                            Text(
                                if (address.suspended) {
                                    stringResource(R.string.addresses_suspended)
                                } else {
                                    address.comment
                                },
                            )
                        }
                    } else {
                        null
                    },
                trailingContent = {
                    IconButton(onClick = onToggleFavorite, enabled = !busy) {
                        Icon(
                            if (address.favorite) Icons.Filled.Star else Icons.Outlined.Star,
                            contentDescription = stringResource(favoriteLabel(address.favorite)),
                            tint =
                                if (address.favorite) {
                                    MaterialTheme.colorScheme.tertiary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                        )
                    }
                },
                modifier =
                    Modifier.combinedClickable(
                        onClick = {},
                        onLongClick = onLongPress,
                    ),
            )
            DropdownMenu(expanded = menuOpen, onDismissRequest = onDismissMenu) {
                DropdownMenuItem(
                    text = { Text(stringResource(favoriteLabel(address.favorite))) },
                    onClick = {
                        onDismissMenu()
                        onToggleFavorite()
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.addresses_revoke), color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        onDismissMenu()
                        onRevoke()
                    },
                )
            }
        }
    }
}

private fun favoriteLabel(favorite: Boolean): Int =
    if (favorite) R.string.addresses_unfavorite else R.string.addresses_favorite
