package com.cabalmail.android.ui.feeds

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.navigation.ResumeSessionStore
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.rss.ItemQuery
import com.cabalmail.kit.rss.RssStore
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.MarkAsRead
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class FeedItemListUiState(
    val scope: RssItemScope,
    val subscription: RssSubscription? = null,
    val folder: RssFolder? = null,
    val items: List<RssItem> = emptyList(),
    val filter: RssItemFilter = RssItemFilter.DEFAULT_FOR_FEEDS,
    val ordering: RssOrderingMode = RssOrderingMode.NEWEST_FIRST,
    val searchQuery: String = "",
    val syncing: Boolean = false,
    val loadingOlder: Boolean = false,
    /** Whether the store has more rows beyond the pages read so far. */
    val hasMoreLocal: Boolean = false,
    /** Whether the server has no history beyond what is cached (single-feed scopes). */
    val olderExhausted: Boolean = false,
    val error: String? = null,
    /** Items with a queued local change (the row's "Change queued" mark). */
    val pendingIds: Set<String> = emptySet(),
    /** Feed titles by subscription id, for rows in multi-feed scopes. */
    val subscriptionTitles: Map<String, String> = emptyMap(),
    val hasLoaded: Boolean = false,
) {
    val canSearch: Boolean get() = subscription != null
    val canLoadOlder: Boolean get() = subscription != null && !olderExhausted
    val allRead: Boolean get() = items.all { it.isRead }

    /** The feed a row belongs to, for multi-feed scopes: its title, else the article's host. */
    fun feedName(item: RssItem): String =
        subscriptionTitles[item.subscriptionId]?.takeIf { it.isNotEmpty() }
            ?: runCatching { java.net.URI(item.url).host }.getOrNull().orEmpty()
}

/**
 * One feed list (a feed, a folder, or All Feeds), the Apple
 * `FeedItemListViewModel`. Reads pages from the store; syncs the scope's
 * feeds on demand; applies read and favorite changes optimistically and
 * posts them on the bus; keeps the filter pill sticky on the scope's row
 * or the All Feeds preference. Takes narrow collaborators rather than the
 * container so it unit-tests against the kit's in-memory store.
 */
class FeedItemListViewModel(
    scope: RssItemScope,
    private val store: RssStore,
    private val engine: suspend () -> RssSyncEngine,
    private val events: FeedEventBus,
    private val preferences: StateFlow<AppPreferences>,
    private val updatePreferences: suspend ((AppPreferences) -> AppPreferences) -> Unit,
    session: ResumeSessionStore? = null,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FeedItemListUiState(scope = scope))
    val state: StateFlow<FeedItemListUiState> = mutableState.asStateFlow()

    private var loaded = 0
    private var postingSelf = false

    init {
        // Where the user is now, for the next cold launch (resume-session
        // plan, Phase B). The item, when one opens, records itself.
        session?.recordFeedScope(scope.token)
        viewModelScope.launch {
            events.events.collect { event ->
                when (event) {
                    is FeedEvent.ItemChanged -> patch(event.item)
                    FeedEvent.Changed -> if (!postingSelf && mutableState.value.items.size <= PAGE_SIZE) reload()
                    FeedEvent.CatalogChanged -> Unit
                }
            }
        }
        viewModelScope.launch {
            start()
        }
    }

    /**
     * Resolves the scope's row from the store — the subscription or folder
     * whose stored pill and ordering the list opens on — then reads the
     * first page and syncs. Read here, at creation, not handed in by a
     * parent: a parent that has not resolved the row yet would open the
     * list on the defaults (the Apple 1.17.0 round).
     */
    private suspend fun start() {
        val scope = mutableState.value.scope
        val subscription = (scope as? RssItemScope.Subscription)?.let { store.subscription(it.subscriptionId) }
        val folder = (scope as? RssItemScope.Folder)?.let { store.folder(it.folderId) }
        mutableState.update {
            it.copy(
                subscription = subscription,
                folder = folder,
                filter =
                    FeedListFilterPolicy.initial(
                        scope,
                        subscription,
                        folder,
                        preferences.value.effectiveFeedsAllFilter,
                    ),
                ordering = subscription?.orderingMode ?: RssOrderingMode.NEWEST_FIRST,
            )
        }
        reload()
        sync()
    }

    /** The first page from the store (or the search results), no network. */
    suspend fun reload() {
        val current = mutableState.value
        try {
            val feedId = current.subscription?.feedId
            val items =
                if (current.searchQuery.isNotBlank() && feedId != null) {
                    store.search(feedId, current.searchQuery)
                } else {
                    store.items(ItemQuery(current.scope, current.filter, current.ordering, PAGE_SIZE, 0))
                }
            val searching = current.searchQuery.isNotBlank() && feedId != null
            val olderExhausted = feedId?.let { store.syncState(it).olderExhausted } ?: false
            val titles =
                if (current.subscription == null) {
                    store.subscriptions().associate { it.subscriptionId to it.displayTitle }
                } else {
                    emptyMap()
                }
            loaded = items.size
            mutableState.update {
                it.copy(
                    items = items,
                    hasMoreLocal = !searching && items.size == PAGE_SIZE,
                    olderExhausted = olderExhausted,
                    subscriptionTitles = titles,
                    hasLoaded = true,
                )
            }
            refreshPendingMarks()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            mutableState.update {
                it.copy(
                    error = feedUserMessage(exception, "Could not read the feed"),
                    hasLoaded = true,
                )
            }
        }
    }

    /** The next page from the store, appended (the last row's appearance calls this). */
    fun loadMore() {
        val current = mutableState.value
        if (!current.hasMoreLocal || current.searchQuery.isNotBlank()) return
        viewModelScope.launch {
            val page =
                runCatching {
                    store.items(ItemQuery(current.scope, current.filter, current.ordering, PAGE_SIZE, loaded))
                }.getOrNull() ?: return@launch
            loaded += page.size
            mutableState.update { it.copy(items = it.items + page, hasMoreLocal = page.size == PAGE_SIZE) }
            refreshPendingMarks()
        }
    }

    /** Syncs every feed in scope, drains the queue, reads again, and tells the other screens. */
    fun sync() {
        if (mutableState.value.syncing) return
        mutableState.update { it.copy(syncing = true, error = null) }
        viewModelScope.launch {
            try {
                val engine = engine()
                val feedIds = store.feedIds(mutableState.value.scope).toSet()
                val subs = store.subscriptions().filter { it.feedId in feedIds }
                var failure: Throwable? = null
                for (sub in subs) {
                    try {
                        engine.syncItems(sub)
                    } catch (exception: Exception) {
                        if (exception is CancellationException) throw exception
                        failure = failure ?: exception
                    }
                }
                runCatching { engine.drainPending() }
                reload()
                if (failure != null && subs.isNotEmpty()) {
                    mutableState.update { it.copy(error = feedUserMessage(failure, "Could not refresh the feed")) }
                }
                postBroad()
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, "Could not refresh the feed")) }
            } finally {
                mutableState.update { it.copy(syncing = false) }
            }
        }
    }

    /** The fifteen-minute foreground refresh. */
    fun poll() = sync()

    /** Pulls the next page of older items from the server ("Load older" / "Search older"). */
    fun loadOlder() {
        val subscription = mutableState.value.subscription ?: return
        if (mutableState.value.loadingOlder) return
        mutableState.update { it.copy(loadingOlder = true) }
        viewModelScope.launch {
            try {
                val received = engine().loadOlder(subscription)
                if (received == 0) mutableState.update { it.copy(olderExhausted = true) }
                reload()
                postBroad()
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, "Could not load older items")) }
            } finally {
                mutableState.update { it.copy(loadingOlder = false) }
            }
        }
    }

    /**
     * The pill: applied at once, then written back to the scope's row (or
     * the All Feeds preference) when it differs from what is stored.
     */
    fun setFilter(filter: RssItemFilter) {
        val current = mutableState.value
        if (current.filter == filter) return
        mutableState.update { it.copy(filter = filter) }
        viewModelScope.launch {
            reload()
            when (val scope = current.scope) {
                RssItemScope.All ->
                    runCatching { updatePreferences { it.copy(feedsAllFilter = filter) } }
                is RssItemScope.Subscription -> {
                    val sub = current.subscription ?: return@launch
                    val update = FeedListFilterPolicy.stickyUpdate(sub, filter) ?: return@launch
                    persistSubscription(sub, update)
                }
                is RssItemScope.Folder -> {
                    val folder = current.folder ?: return@launch
                    val update = FeedListFilterPolicy.stickyUpdate(folder, filter) ?: return@launch
                    mutableState.update { it.copy(folder = folder.applying(update)) }
                    runCatching { engine().updateFolder(folder, update) }
                        .onSuccess { updated -> mutableState.update { it.copy(folder = updated) } }
                    events.post(FeedEvent.CatalogChanged)
                }
            }
        }
    }

    /** The ordering, applied at once and stored on the feed's row (single-feed scopes). */
    fun setOrdering(ordering: RssOrderingMode) {
        val current = mutableState.value
        if (current.ordering == ordering) return
        mutableState.update { it.copy(ordering = ordering) }
        viewModelScope.launch {
            reload()
            val sub = current.subscription ?: return@launch
            if (sub.orderingMode != ordering) persistSubscription(sub, RssSubscriptionUpdate(orderingMode = ordering))
        }
    }

    fun setSearchQuery(query: String) {
        if (mutableState.value.searchQuery == query) return
        mutableState.update { it.copy(searchQuery = query) }
        viewModelScope.launch { reload() }
    }

    fun setRead(
        item: RssItem,
        isRead: Boolean,
    ) {
        val changed = item.copy(isRead = isRead, isReadExplicit = true)
        patch(changed)
        viewModelScope.launch {
            runCatching { engine().setRead(item, isRead) }
            events.post(FeedEvent.ItemChanged(changed))
            refreshPendingMarks()
        }
    }

    fun setFavorite(
        item: RssItem,
        isFavorite: Boolean,
    ) {
        val changed = item.copy(isFavorite = isFavorite)
        patch(changed)
        viewModelScope.launch {
            runCatching { engine().setFavorite(item, isFavorite) }
            events.post(FeedEvent.ItemChanged(changed))
            refreshPendingMarks()
        }
    }

    /** Every subscription in scope; the screen confirms first. */
    fun markAllRead() {
        viewModelScope.launch {
            try {
                val engine = engine()
                val feedIds = store.feedIds(mutableState.value.scope).toSet()
                store.subscriptions().filter { it.feedId in feedIds }.forEach { engine.markAllRead(it.subscriptionId) }
                reload()
                postBroad()
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = feedUserMessage(exception, "Could not mark all read")) }
            }
        }
    }

    /** Opening an item marks it read when the feed reader's own preference says so. */
    fun didOpen(item: RssItem) {
        if (preferences.value.effectiveRssMarkAsRead != MarkAsRead.ON_OPEN || item.isRead) return
        setRead(item, true)
    }

    private suspend fun persistSubscription(
        subscription: RssSubscription,
        update: RssSubscriptionUpdate,
    ) {
        mutableState.update { it.copy(subscription = subscription.applying(update)) }
        runCatching { engine().updateSubscription(subscription, update) }
            .onSuccess { updated -> mutableState.update { it.copy(subscription = updated) } }
        events.post(FeedEvent.CatalogChanged)
    }

    /** Patches one row in place; a row that stops matching the filter stays until the next reload. */
    private fun patch(changed: RssItem) {
        mutableState.update { state ->
            state.copy(
                items =
                    state.items.map {
                        if (it.id ==
                            changed.id
                        ) {
                            it.copy(isRead = changed.isRead, isFavorite = changed.isFavorite)
                        } else {
                            it
                        }
                    },
            )
        }
    }

    private suspend fun refreshPendingMarks() {
        val pending =
            mutableState.value.items
                .filter { runCatching { store.hasPending(it.feedId, it.sortKey) }.getOrDefault(false) }
                .map { it.id }
                .toSet()
        mutableState.update { it.copy(pendingIds = pending) }
    }

    private fun postBroad() {
        postingSelf = true
        events.post(FeedEvent.Changed)
        postingSelf = false
    }

    companion object {
        const val PAGE_SIZE = 100

        fun factory(
            container: AppContainer,
            scope: RssItemScope,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    FeedItemListViewModel(
                        scope = scope,
                        store = container.rssStore,
                        engine = { container.requireRssSync() },
                        events = container.feedEvents,
                        preferences = container.preferences.preferences,
                        updatePreferences = { transform -> container.preferences.update(transform) },
                        session = container.resumeSession,
                    )
                }
            }
    }
}
