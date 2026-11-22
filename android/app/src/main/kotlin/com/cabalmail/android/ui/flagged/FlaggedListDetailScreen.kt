package com.cabalmail.android.ui.flagged

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import com.cabalmail.android.ui.feeds.FeedItemDetailScreen
import com.cabalmail.android.ui.feeds.FeedItemDetailViewModel
import com.cabalmail.android.ui.mail.ListDetailDragHandle
import com.cabalmail.android.ui.mail.MessageDetailScreen
import com.cabalmail.android.ui.mail.MessageDetailViewModel
import com.cabalmail.android.ui.mail.PaneLayoutScreen
import com.cabalmail.android.ui.mail.rememberListPaneExpansion
import com.cabalmail.kit.models.ItemRef
import com.cabalmail.kit.models.ref
import kotlinx.coroutines.launch

/**
 * The Flagged view on a wide window: the list and the open item side by
 * side, the sibling of `MailListDetailScreen` and `FeedListDetailScreen`.
 * The detail pane shows whichever reader the open row needs, the mail
 * reader for a message and the feed reader for a feed item, each as it is
 * in its own medium's pane. Opening a row selects the detail pane, keyed
 * by the row's [ItemRef.key]. System back clears the pane where the window
 * shows one pane at a time; where both show it leaves the view, as it
 * does in the mail and feed layouts.
 *
 * There is no leading pane: the view belongs to neither medium, so
 * neither's folder list or feed tree leads it, and Back from the list
 * returns to the one it was opened from. The divider drags, and its place
 * is remembered apart from the mail and feed layouts'.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun FlaggedListDetailScreen(
    container: AppContainer,
    state: FlaggedUiState,
    viewModel: FlaggedViewModel,
    onBack: () -> Unit,
    openCompose: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val online by container.connectivity.online.collectAsState()
    val config by container.configService.config.collectAsState()

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val directive = calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())
        val listExpansion =
            rememberListPaneExpansion(
                store = container.paneWidths,
                screen = PaneLayoutScreen.FLAGGED,
                scaffold = maxWidth,
                spacer = directive.horizontalPartitionSpacerSize,
            )
        val navigator = rememberListDetailPaneScaffoldNavigator<String>(scaffoldDirective = directive)
        val openKey = navigator.currentDestination?.contentKey
        val open: (ItemRef) -> Unit = { ref ->
            scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, ref.key) }
        }
        val close: () -> Unit = { scope.launch { navigator.navigateBack() } }

        NavigableListDetailPaneScaffold(
            navigator = navigator,
            paneExpansionState = listExpansion.state,
            paneExpansionDragHandle = { handle -> ListDetailDragHandle(handle, listExpansion.interactionSource) },
            listPane = {
                AnimatedPane(modifier = Modifier.onSizeChanged { listExpansion.listWidthPx = it.width }) {
                    FlaggedScreen(
                        state = state,
                        viewModel = viewModel,
                        online = online,
                        bimiLookup = container.bimiLookup,
                        mailDomains = config?.mailDomains.orEmpty(),
                        onOpenMessage = { envelope -> envelope.ref()?.let(open) },
                        onOpenItem = { item -> open(item.ref) },
                        onBack = onBack,
                        highlightedKey = openKey,
                    )
                }
            },
            detailPane = {
                AnimatedPane {
                    when (val ref = openKey?.let(ItemRef::parse)) {
                        null ->
                            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text(
                                    text = stringResource(R.string.flagged_select_item),
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        is ItemRef.Mail ->
                            key(ref.key) {
                                val detailViewModel: MessageDetailViewModel =
                                    viewModel(
                                        key = ref.key,
                                        factory = MessageDetailViewModel.factory(container, ref.folder, ref.uid),
                                    )
                                val detailState by detailViewModel.state.collectAsState()
                                MessageDetailScreen(
                                    state = detailState,
                                    viewModel = detailViewModel,
                                    bimiLookup = container.bimiLookup,
                                    // No list to advance through, as from
                                    // Search: a dispose empties the pane.
                                    onBack = close,
                                    onCompose = { draftId, _ -> openCompose(draftId) },
                                    showBack = false,
                                )
                            }
                        is ItemRef.Feed ->
                            key(ref.key) {
                                val detailViewModel: FeedItemDetailViewModel =
                                    viewModel(
                                        key = ref.key,
                                        factory = FeedItemDetailViewModel.factory(container, ref.feedId, ref.sortKey),
                                    )
                                val detailState by detailViewModel.state.collectAsState()
                                FeedItemDetailScreen(
                                    state = detailState,
                                    viewModel = detailViewModel,
                                    online = online,
                                    onBack = close,
                                    showBack = false,
                                )
                            }
                    }
                }
            },
        )
    }
}
