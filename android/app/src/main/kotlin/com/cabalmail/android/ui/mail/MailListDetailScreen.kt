package com.cabalmail.android.ui.mail

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import kotlinx.coroutines.launch

/**
 * Tablet / foldable mail flow (plan §7.2): the message list and the open
 * message side by side in a [NavigableListDetailPaneScaffold]. The pane
 * directive comes from the window's adaptive info, so a hinge splits the
 * panes rather than running under content. Opening a row selects the
 * detail pane instead of pushing a route; system back clears it.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun MailListDetailScreen(
    container: AppContainer,
    folder: String,
    listViewModel: MessageListViewModel,
    listState: MessageListUiState,
    onOpenSearch: () -> Unit,
    onBack: () -> Unit,
    onCompose: () -> Unit,
    openCompose: (String) -> Unit,
    /** A message to open in the detail pane on first show (resume cursor). */
    initialUid: Long? = null,
) {
    val navigator = rememberListDetailPaneScaffoldNavigator<Long>()
    val scope = rememberCoroutineScope()
    val config by container.configService.config.collectAsState()
    val mailDomains = config?.mailDomains.orEmpty()
    val openUid = navigator.currentDestination?.contentKey
    LaunchedEffect(initialUid) {
        if (initialUid != null && navigator.currentDestination?.contentKey == null) {
            navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, initialUid)
        }
    }

    NavigableListDetailPaneScaffold(
        navigator = navigator,
        listPane = {
            AnimatedPane {
                MessageListScreen(
                    folder = folder,
                    state = listState,
                    viewModel = listViewModel,
                    bimiLookup = container.bimiLookup,
                    mailDomains = mailDomains,
                    onOpenMessage = { envelope ->
                        scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, envelope.id) }
                    },
                    onOpenSearch = onOpenSearch,
                    onBack = onBack,
                    onCompose = onCompose,
                    // With a message open the reader owns the chords.
                    handleShortcuts = openUid == null,
                    highlightedUid = openUid,
                )
            }
        },
        detailPane = {
            AnimatedPane {
                val uid = navigator.currentDestination?.contentKey
                if (uid == null) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            text = stringResource(R.string.detail_placeholder),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    key(folder, uid) {
                        val detailViewModel: MessageDetailViewModel =
                            viewModel(
                                key = "$folder/$uid",
                                factory = MessageDetailViewModel.factory(container, folder, uid),
                            )
                        val detailState by detailViewModel.state.collectAsState()
                        MessageDetailScreen(
                            state = detailState,
                            viewModel = detailViewModel,
                            bimiLookup = container.bimiLookup,
                            onBack = { scope.launch { navigator.navigateBack() } },
                            onCompose = { draftId, _ -> openCompose(draftId) },
                            showBack = false,
                            computeAdvance = { disposedUid, advance ->
                                disposeAdvanceTarget(listState.filteredRows, disposedUid, advance)?.id
                            },
                            onOpenMessage = { target ->
                                scope.launch {
                                    navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, target)
                                }
                            },
                        )
                    }
                }
            }
        },
    )
}
