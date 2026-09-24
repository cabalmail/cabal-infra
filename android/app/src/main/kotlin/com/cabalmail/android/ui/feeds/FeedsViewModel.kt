package com.cabalmail.android.ui.feeds

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.rss.RssStore
import com.cabalmail.kit.rss.RssSyncEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class FeedsUiState(
    val folders: List<RssFolder> = emptyList(),
    val subscriptions: List<RssSubscription> = emptyList(),
    /** Keyed by subscription id; absent = zero. */
    val unreadCounts: Map<String, Int> = emptyMap(),
    /** Cached items per subscription id; absent = zero. The Total badge modes read this. */
    val totalCounts: Map<String, Int> = emptyMap(),
    val refreshing: Boolean = false,
    val error: String? = null,
    /** Distinguishes an empty catalog from one not read yet. */
    val hasLoaded: Boolean = false,
) {
    val hasSubscriptions: Boolean get() = subscriptions.isNotEmpty()

    fun title(scope: RssItemScope): String? =
        when (scope) {
            RssItemScope.All -> null
            is RssItemScope.Folder -> folders.firstOrNull { it.folderId == scope.folderId }?.name
            is RssItemScope.Subscription ->
                subscriptions.firstOrNull { it.subscriptionId == scope.subscriptionId }?.displayTitle
        }
}

/** Where the feed tree is scrolled to: the first visible row and its offset in pixels. */
data class FeedTreeScroll(
    val index: Int = 0,
    val offset: Int = 0,
)

/**
 * The feed list (folders with feeds as leaves), the Apple
 * `FeedSidebarViewModel`: [load] is a pure store read so the tree renders
 * offline; [refresh] pulls the catalog, drops the web profiles of departed
 * subscriptions, syncs every feed, and reads again. Takes the store, the
 * engine, and the bus rather than the container so it unit-tests against
 * the kit's in-memory store.
 */
class FeedsViewModel(
    private val store: RssStore,
    private val engine: suspend () -> RssSyncEngine,
    private val events: FeedEventBus,
    /** Drops the per-subscription web profiles the catalog refresh reports as gone. */
    private val onDroppedProfiles: (List<String>) -> Unit = {},
) : ViewModel() {
    private val mutableState = MutableStateFlow(FeedsUiState())
    val state: StateFlow<FeedsUiState> = mutableState.asStateFlow()

    /**
     * The wide-window pane's scroll position. Opening a scope replaces the
     * items entry, and the pane inside it, so the position lives here with
     * the tree rather than in the pane's own list state, which starts over
     * at the top on each switch.
     */
    var treeScroll: FeedTreeScroll = FeedTreeScroll()

    init {
        viewModelScope.launch {
            events.events.collect { event ->
                when (event) {
                    is FeedEvent.ItemChanged -> reloadCounts()
                    FeedEvent.Changed, FeedEvent.CatalogChanged -> load()
                }
            }
        }
        viewModelScope.launch {
            load()
            refresh()
        }
    }

    /** Reads the store; no network. */
    suspend fun load() {
        try {
            val folders = store.folders()
            val subscriptions = store.subscriptions()
            val counts = store.unreadCounts()
            val totals = store.totalCounts()
            mutableState.update {
                it.copy(
                    folders = folders,
                    subscriptions = subscriptions,
                    unreadCounts = counts,
                    totalCounts = totals,
                    hasLoaded = true,
                )
            }
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            mutableState.update { it.copy(error = feedUserMessage(exception, "Could not read feeds")) }
        }
    }

    suspend fun reloadCounts() {
        val counts = runCatching { store.unreadCounts() }.getOrNull() ?: return
        val totals = runCatching { store.totalCounts() }.getOrNull() ?: return
        mutableState.update { it.copy(unreadCounts = counts, totalCounts = totals) }
    }

    /** Catalog, then every feed; coalesced while one is running. */
    fun refresh() {
        if (mutableState.value.refreshing) return
        mutableState.update { it.copy(refreshing = true, error = null) }
        viewModelScope.launch {
            try {
                val engine = engine()
                val diff = engine.refreshCatalog()
                load()
                if (diff.removedDataStoreUuids.isNotEmpty()) onDroppedProfiles(diff.removedDataStoreUuids)
                val failures = engine.syncAll()
                load()
                val subs = mutableState.value.subscriptions
                // One line when every feed failed (offline, say); a single
                // feed's trouble shows on its own row as health, not here.
                val first = failures.values.firstOrNull()
                if (first != null && subs.isNotEmpty() && failures.size == subs.size) {
                    mutableState.update { it.copy(error = feedUserMessage(first, "Could not refresh feeds")) }
                }
                events.post(FeedEvent.Changed)
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, "Could not refresh feeds")) }
            } finally {
                mutableState.update { it.copy(refreshing = false) }
            }
        }
    }

    /** The fifteen-minute foreground refresh. */
    fun poll() = refresh()

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    FeedsViewModel(
                        store = container.rssStore,
                        engine = { container.requireRssSync() },
                        events = container.feedEvents,
                        onDroppedProfiles = { FeedWebProfiles.drop(container.applicationContext, it) },
                    )
                }
            }
    }
}
