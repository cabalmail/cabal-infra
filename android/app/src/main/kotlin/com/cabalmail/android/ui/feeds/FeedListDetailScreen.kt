package com.cabalmail.android.ui.feeds

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
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cabalmail.android.AppContainer
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.FOLDER_PANE_WIDTH
import com.cabalmail.android.ui.mail.fitsThreePanes
import com.cabalmail.android.ui.mail.threePaneListWidth
import kotlinx.coroutines.launch

/**
 * The wide-window feeds layout, the sibling of `MailListDetailScreen`:
 * item list and open item side by side, the feed tree leading when the
 * window fits three panes. Opening a row selects the detail pane, keyed
 * by the item's `feedId#sortKey`.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun FeedListDetailScreen(
    container: AppContainer,
    title: String,
    listViewModel: FeedItemListViewModel,
    listState: FeedItemListUiState,
    onBack: () -> Unit,
    initialItemId: String? = null,
    feedPane: (@Composable () -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    val online by container.connectivity.online.collectAsState()

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val threePane = feedPane != null && fitsThreePanes(maxWidth)
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
        val navigator = rememberListDetailPaneScaffoldNavigator<String>(scaffoldDirective = directive)
        val openId = navigator.currentDestination?.contentKey
        LaunchedEffect(initialItemId) {
            if (initialItemId != null && navigator.currentDestination?.contentKey == null) {
                navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, initialItemId)
            }
        }

        Row(modifier = Modifier.fillMaxSize()) {
            if (threePane && feedPane != null) {
                Box(modifier = Modifier.width(FOLDER_PANE_WIDTH).fillMaxHeight()) { feedPane() }
                VerticalDivider()
            }
            NavigableListDetailPaneScaffold(
                navigator = navigator,
                modifier = Modifier.weight(1f),
                listPane = {
                    AnimatedPane {
                        FeedItemListScreen(
                            title = title,
                            state = listState,
                            viewModel = listViewModel,
                            onOpenItem = { item ->
                                scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, item.id) }
                            },
                            onBack = if (threePane) null else onBack,
                            highlightedId = openId,
                        )
                    }
                },
                detailPane = {
                    AnimatedPane {
                        val id = navigator.currentDestination?.contentKey
                        val parts = id?.let(FeedRoutes::splitItemId)
                        if (parts == null) {
                            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text(
                                    text = stringResource(R.string.feeds_select_item),
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        } else {
                            val (feedId, sortKey) = parts
                            key(id) {
                                val detailViewModel: FeedItemDetailViewModel =
                                    viewModel(
                                        key = id,
                                        factory = FeedItemDetailViewModel.factory(container, feedId, sortKey),
                                    )
                                val detailState by detailViewModel.state.collectAsState()
                                FeedItemDetailScreen(
                                    state = detailState,
                                    viewModel = detailViewModel,
                                    online = online,
                                    onBack = { scope.launch { navigator.navigateBack() } },
                                    showBack = false,
                                )
                            }
                        }
                    }
                },
            )
        }
    }
}
