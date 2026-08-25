package com.cabalmail.android.ui.mail

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import kotlinx.coroutines.launch

/** Width of the folder pane in the three-pane layout. */
internal val FOLDER_PANE_WIDTH = 200.dp

/**
 * Narrowest window the three-pane layout fits: the folder pane plus two
 * message panes of at least 220dp each.
 */
internal val THREE_PANE_MIN_WIDTH = 640.dp

/** Whether the mail view's width fits the folder pane plus two message panes. */
internal fun fitsThreePanes(width: Dp): Boolean = width >= THREE_PANE_MIN_WIDTH

/** List-pane preferred width beside the folder pane: half of what is left. */
internal fun threePaneListWidth(width: Dp): Dp = (width - FOLDER_PANE_WIDTH) / 2

/**
 * Tablet / foldable / landscape-phone mail flow (plan §7.2): the message
 * list and the open message side by side in a
 * [NavigableListDetailPaneScaffold], with the folder list as a third
 * leading pane when the window fits it. The pane directive comes from the
 * window's adaptive info, so a hinge splits the panes rather than running
 * under content; the three-pane layout forces both message panes visible
 * (the window-level directive would keep a medium-width window — a phone
 * in landscape — to one pane at a time) and splits the width left of the
 * folder pane evenly between them. Opening a row selects the detail pane
 * instead of pushing a route; system back clears it.
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
    /** The folder pane, composed leading when the window fits three panes. */
    folderPane: (@Composable () -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val config by container.configService.config.collectAsState()
    val mailDomains = config?.mailDomains.orEmpty()

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val threePane = folderPane != null && fitsThreePanes(maxWidth)
        val baseDirective = calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())
        val directive =
            if (threePane) {
                PaneScaffoldDirective(
                    maxHorizontalPartitions = 2,
                    horizontalPartitionSpacerSize = baseDirective.horizontalPartitionSpacerSize,
                    maxVerticalPartitions = baseDirective.maxVerticalPartitions,
                    verticalPartitionSpacerSize = baseDirective.verticalPartitionSpacerSize,
                    defaultPanePreferredWidth = threePaneListWidth(maxWidth),
                    excludedBounds = baseDirective.excludedBounds,
                )
            } else {
                baseDirective
            }
        val navigator = rememberListDetailPaneScaffoldNavigator<Long>(scaffoldDirective = directive)
        val openUid = navigator.currentDestination?.contentKey
        LaunchedEffect(initialUid) {
            if (initialUid != null && navigator.currentDestination?.contentKey == null) {
                navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, initialUid)
            }
        }

        Row(modifier = Modifier.fillMaxSize()) {
            if (threePane && folderPane != null) {
                Box(modifier = Modifier.width(FOLDER_PANE_WIDTH).fillMaxHeight()) {
                    folderPane()
                }
                VerticalDivider()
            }
            NavigableListDetailPaneScaffold(
                navigator = navigator,
                modifier = Modifier.weight(1f),
                listPane = {
                    AnimatedPane {
                        MessageListScreen(
                            folder = folder,
                            state = listState,
                            viewModel = listViewModel,
                            bimiLookup = container.bimiLookup,
                            mailDomains = mailDomains,
                            onOpenMessage = { envelope ->
                                scope.launch {
                                    navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, envelope.id)
                                }
                            },
                            onOpenSearch = onOpenSearch,
                            onBack = onBack,
                            onCompose = onCompose,
                            // With a message open the reader owns the chords.
                            handleShortcuts = openUid == null,
                            highlightedUid = openUid,
                            // Beside a visible folder pane there is no hub to
                            // go back to.
                            showBack = !threePane,
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
    }
}
