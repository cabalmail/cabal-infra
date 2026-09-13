package com.cabalmail.android.ui.feeds

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
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

data class FeedItemDetailUiState(
    val item: RssItem? = null,
    val subscription: RssSubscription? = null,
    val showingArticle: Boolean = false,
    val readerMode: Boolean = true,
    val remoteContentAllowed: Boolean = false,
    val loaded: Boolean = false,
    val error: String? = null,
) {
    /** The article link, when it is a web address. */
    val articleUrl: String?
        get() =
            item?.url?.takeIf {
                val lower = it.lowercase()
                lower.startsWith("http://") || lower.startsWith("https://")
            }
}

/**
 * One feed item's reader, the Apple `FeedItemDetailViewModel`. The item
 * and its subscription are read from the store at creation, and the
 * feed's defaults (open mode, styling, remote content) decide the first
 * render; the three toggles write back to the feed's row so the next item
 * opens the same way, optimistic in-memory first, the server round trip
 * best-effort. Mark-read-on-open follows the feed reader's own
 * preference.
 */
class FeedItemDetailViewModel(
    private val feedId: String,
    private val sortKey: String,
    private val store: RssStore,
    private val engine: suspend () -> RssSyncEngine,
    private val events: FeedEventBus,
    private val preferences: StateFlow<AppPreferences>,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FeedItemDetailUiState())
    val state: StateFlow<FeedItemDetailUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            events.events.collect { event ->
                if (event is FeedEvent.ItemChanged && event.item.id == "$feedId#$sortKey") {
                    mutableState.update { state ->
                        state.copy(
                            item = state.item?.copy(isRead = event.item.isRead, isFavorite = event.item.isFavorite),
                        )
                    }
                }
            }
        }
        viewModelScope.launch { load() }
    }

    private suspend fun load() {
        try {
            val item = store.item(feedId, sortKey)
            val subscription = item?.subscriptionId?.ifEmpty { null }?.let { store.subscription(it) }
            val policy =
                FeedDetailPolicy.initial(
                    subscription = subscription,
                    hasArticleUrl = FeedItemDetailUiState(item = item).articleUrl != null,
                    globalRemoteContent = preferences.value.loadRemoteContent,
                )
            mutableState.update {
                it.copy(
                    item = item,
                    subscription = subscription,
                    showingArticle = policy.showsArticle,
                    readerMode = policy.readerMode,
                    remoteContentAllowed = policy.remoteContentAllowed,
                    loaded = true,
                )
            }
            if (item != null && !item.isRead && preferences.value.effectiveRssMarkAsRead == MarkAsRead.ON_OPEN) {
                setRead(true)
            }
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            mutableState.update {
                it.copy(
                    error = feedUserMessage(exception, "Could not open the item"),
                    loaded = true,
                )
            }
        }
    }

    fun setRead(isRead: Boolean) {
        val item = mutableState.value.item ?: return
        val changed = item.copy(isRead = isRead, isReadExplicit = true)
        mutableState.update { it.copy(item = changed) }
        viewModelScope.launch {
            runCatching { engine().setRead(item, isRead) }
            events.post(FeedEvent.ItemChanged(changed))
        }
    }

    fun setFavorite(isFavorite: Boolean) {
        val item = mutableState.value.item ?: return
        val changed = item.copy(isFavorite = isFavorite)
        mutableState.update { it.copy(item = changed) }
        viewModelScope.launch {
            runCatching { engine().setFavorite(item, isFavorite) }
            events.post(FeedEvent.ItemChanged(changed))
        }
    }

    /** Article view on or off; writes `default_open_mode` when there is an article to open. */
    fun toggleArticle() {
        val current = mutableState.value
        val showing = !current.showingArticle
        mutableState.update { it.copy(showingArticle = showing) }
        current.subscription?.let { sub ->
            persistDefault(FeedDetailPolicy.articleUpdate(sub, showing, current.articleUrl != null))
        }
    }

    /** Reader or original styling; writes `default_styling`. */
    fun toggleReaderMode() {
        val current = mutableState.value
        val reader = !current.readerMode
        mutableState.update { it.copy(readerMode = reader) }
        current.subscription?.let { persistDefault(FeedDetailPolicy.stylingUpdate(it, reader)) }
    }

    /** Remote content on or off for this feed; writes an explicit `default_remote_content`. */
    fun toggleRemoteContent() {
        val current = mutableState.value
        val allowed = !current.remoteContentAllowed
        mutableState.update { it.copy(remoteContentAllowed = allowed) }
        current.subscription?.let { persistDefault(FeedDetailPolicy.remoteContentUpdate(it, allowed)) }
    }

    /**
     * Holds the updated row at once (so a second toggle compares against
     * the first write) and pushes it; a failure leaves the reader's state
     * alone — the next catalog refresh reconciles the row.
     */
    private fun persistDefault(update: RssSubscriptionUpdate?) {
        if (update == null) return
        val subscription = mutableState.value.subscription ?: return
        mutableState.update { it.copy(subscription = subscription.applying(update)) }
        viewModelScope.launch {
            runCatching { engine().updateSubscription(subscription, update) }
                .onSuccess { updated -> mutableState.update { it.copy(subscription = updated) } }
            events.post(FeedEvent.CatalogChanged)
        }
    }

    companion object {
        fun factory(
            container: AppContainer,
            feedId: String,
            sortKey: String,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    FeedItemDetailViewModel(
                        feedId = feedId,
                        sortKey = sortKey,
                        store = container.rssStore,
                        engine = { container.requireRssSync() },
                        events = container.feedEvents,
                        preferences = container.preferences.preferences,
                    )
                }
            }
    }
}
