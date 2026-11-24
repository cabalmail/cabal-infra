package com.cabalmail.android.ui.flagged

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.cabalmail.android.AppContainer
import com.cabalmail.android.MailEvent
import com.cabalmail.android.ui.feeds.FeedEvent
import com.cabalmail.android.ui.feeds.FeedEventBus
import com.cabalmail.android.ui.feeds.FeedWebProfiles
import com.cabalmail.android.ui.mail.DisposeIntent
import com.cabalmail.android.userMessage
import com.cabalmail.kit.flagged.FlaggedList
import com.cabalmail.kit.flagged.FlaggedPage
import com.cabalmail.kit.flagged.FlaggedSource
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.ItemRef
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.ref
import com.cabalmail.kit.rss.ItemQuery
import com.cabalmail.kit.rss.RssStore
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.MarkAsRead
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant

/** Why the mail half has nothing new to show, for the line above the list. */
enum class FlaggedMailFailure {
    /** No page has landed for this pick: the list holds feed items only. */
    NEVER_LOADED,

    /** A refresh failed: the messages on screen are from the last one that worked. */
    REFRESH,

    /** The next page failed: the list stops at its horizon until it is tried again. */
    NEXT_PAGE,
}

data class FlaggedUiState(
    /** What the view is narrowed to. Any flag unless the user picks one, for the visit. */
    val criterion: FlagCriterion = FlagCriterion.AnyFlag,
    /** Every message loaded so far, in the server's order. */
    val mail: List<Envelope> = emptyList(),
    /** Opaque next-page cursor; null when the server has no more. */
    val mailCursor: String? = null,
    /**
     * The instant the mail half is complete down to ([FlaggedList.mailCutoff]).
     * Before the first page lands nothing is vouched for; once the half is
     * whole, or cannot be had at all, there is no horizon.
     */
    val mailCutoff: Instant? = Instant.MAX,
    val mailLoading: Boolean = false,
    val mailFailure: FlaggedMailFailure? = null,
    /** The failure in words; shown when the device is online, where "offline" would be wrong. */
    val mailFailureMessage: String? = null,
    /** The server stopped at its cap: some messages are not in [mail], and not only old ones. */
    val truncated: Boolean = false,
    /** The folders the search covered, as the server named them. */
    val foldersSearched: List<String> = emptyList(),
    /** Flagged feed items read from the device so far, newest first. */
    val feed: List<RssItem> = emptyList(),
    val feedHasMore: Boolean = false,
    val feedLoaded: Boolean = false,
    /** Feed titles by subscription id, for a feed row's caption. */
    val subscriptionTitles: Map<String, String> = emptyMap(),
    /** Feed items with a queued local change (the row's "Change queued" mark). */
    val pendingIds: Set<String> = emptySet(),
    val refreshing: Boolean = false,
    /** A write that failed, in words. */
    val error: String? = null,
    /** Counts the lists that began afresh (the open, a pick), so the screen scrolls to the top. */
    val listEpoch: Int = 0,
) {
    /**
     * What the list shows. A message whose flag was cleared so that the
     * pick no longer finds it leaves at once, as it does under a folder's
     * Flagged pill; a feed item stays until the half is next read, as it
     * does under a feed's.
     */
    val page: FlaggedPage =
        FlaggedList.merge(
            mail = mail.filter { criterion.matches(it.flags) },
            mailCutoff = mailCutoff,
            feed = feed,
            feedCutoff = FlaggedList.feedCutoff(feed, feedHasMore),
        )

    /** Whether everything there is has been asked for and nothing matched. */
    val isEmpty: Boolean
        get() = feedLoaded && !mailLoading && mailFailure == null && page.rows.isEmpty() && page.next == null

    /** The feed a row belongs to: its title, else the article's host. */
    fun feedName(item: RssItem): String =
        subscriptionTitles[item.subscriptionId]?.takeIf { it.isNotEmpty() }
            ?: runCatching { java.net.URI(item.url).host }.getOrNull().orEmpty()
}

/**
 * The Flagged view (`docs/1.x/post-wave-3/android-parity.md`, leg L4):
 * flagged messages from the server's cross-folder search and flagged feed
 * items from the device's store, as one list ([FlaggedList]).
 *
 * The feed half is read first, since it is local, and held behind the
 * horizon until the first page of mail lands or fails. A refresh keeps
 * the messages on screen until its first page lands, so a refresh that
 * fails (offline) loses nothing. Takes narrow collaborators rather than
 * the container, so it unit-tests against a scripted [FlaggedMail] and the
 * kit's in-memory store.
 */
class FlaggedViewModel(
    private val mail: FlaggedMail,
    private val store: RssStore,
    private val engine: suspend () -> RssSyncEngine,
    /** Brings the device's feed items and their flags up to date; a failure is the Feeds screen's to report. */
    private val syncFeeds: suspend () -> Unit,
    private val feedEvents: FeedEventBus,
    mailEvents: SharedFlow<MailEvent>,
    private val preferences: StateFlow<AppPreferences>,
) : ViewModel() {
    private val mutableState = MutableStateFlow(FlaggedUiState())
    val state: StateFlow<FlaggedUiState> = mutableState.asStateFlow()

    /** The mail request in flight; a pick or a refresh replaces it. */
    private var mailJob: Job? = null

    /** Messages with a move or purge in flight: a repeat would land two copies in the destination. */
    private val disposing = mutableSetOf<ItemRef.Mail>()

    init {
        viewModelScope.launch {
            mailEvents.collect { event ->
                when (event) {
                    is MailEvent.FlagChanged -> patchMailFlags(event.folder, event.uids, event.flag, event.value)
                    is MailEvent.Removed -> dropMail(event.folder, event.uids)
                    is MailEvent.Reconcile ->
                        if (mutableState.value.mail.any { it.folder == event.folder }) loadMail(reset = true)
                    is MailEvent.FolderListChanged -> Unit
                }
            }
        }
        viewModelScope.launch {
            feedEvents.events.collect { event ->
                when (event) {
                    is FeedEvent.ItemChanged -> patchFeed(event.item)
                    FeedEvent.Changed, FeedEvent.CatalogChanged -> readFeed()
                }
            }
        }
        start()
    }

    private fun start() {
        viewModelScope.launch { readFeed() }
        loadMail(reset = true)
        syncFeedsThenRead()
    }

    /** Pull to refresh: both halves again, keeping what is on screen until the new rows land. */
    fun refresh() {
        if (mutableState.value.refreshing) return
        mutableState.update { it.copy(refreshing = true, error = null) }
        loadMail(reset = true)
        syncFeedsThenRead()
    }

    /**
     * Narrows the view to one flag, or back to any: a different list, so
     * both halves start over. For the visit; nothing is stored.
     */
    fun pick(criterion: FlagCriterion) {
        if (mutableState.value.criterion == criterion) return
        mailJob?.cancel()
        mutableState.update {
            FlaggedUiState(
                criterion = criterion,
                subscriptionTitles = it.subscriptionTitles,
                listEpoch = it.listEpoch + 1,
            )
        }
        viewModelScope.launch { readFeed() }
        loadMail(reset = true)
    }

    /** The end of the list came on screen: loads whichever half the horizon is waiting on. */
    fun loadMore() {
        val current = mutableState.value
        when (current.page.next) {
            FlaggedSource.MAIL ->
                if (!current.mailLoading && current.mailFailure == null && current.mailCursor != null) {
                    loadMail(reset = false)
                }
            FlaggedSource.FEED -> viewModelScope.launch { readFeed(more = true) }
            null -> Unit
        }
    }

    /** Retry on the line that says mail could not be had: the first page, or the one that failed. */
    fun retryMail() {
        val current = mutableState.value
        if (current.mailLoading) return
        loadMail(reset = current.mailFailure != FlaggedMailFailure.NEXT_PAGE)
    }

    fun dismissError() {
        mutableState.update { it.copy(error = null) }
    }

    private fun loadMail(reset: Boolean) {
        val criterion = mutableState.value.criterion
        val filters = criterion.mailSearch()
        if (filters == null) {
            // A slot no message can carry: the half is whole, and empty.
            mutableState.update {
                it.copy(
                    mail = emptyList(),
                    mailCursor = null,
                    mailCutoff = null,
                    refreshing = false,
                )
            }
            return
        }
        mailJob?.cancel()
        mailJob =
            viewModelScope.launch {
                mutableState.update { it.copy(mailLoading = true, mailFailure = null, mailFailureMessage = null) }
                try {
                    val cursor = if (reset) null else mutableState.value.mailCursor
                    val result = mail.search(filters, cursor, FlaggedList.MAIL_PAGE_SIZE)
                    mutableState.update { state ->
                        val loaded = if (reset) result.envelopes else appendPage(state.mail, result.envelopes)
                        state.copy(
                            mail = loaded,
                            mailCursor = result.nextCursor,
                            mailCutoff = FlaggedList.mailCutoff(loaded, hasMore = result.nextCursor != null),
                            mailLoading = false,
                            truncated = result.truncated,
                            foldersSearched = if (reset) result.foldersSearched else state.foldersSearched,
                            refreshing = false,
                        )
                    }
                } catch (exception: Exception) {
                    if (exception is CancellationException) throw exception
                    mutableState.update { state ->
                        val failure =
                            when {
                                !reset -> FlaggedMailFailure.NEXT_PAGE
                                state.mail.isEmpty() -> FlaggedMailFailure.NEVER_LOADED
                                else -> FlaggedMailFailure.REFRESH
                            }
                        state.copy(
                            mailLoading = false,
                            mailFailure = failure,
                            mailFailureMessage = userMessage(exception, "Could not load flagged mail"),
                            // With no page ever loaded there is no claim to
                            // make about mail, and the feed half stands alone.
                            mailCutoff = if (failure == FlaggedMailFailure.NEVER_LOADED) null else state.mailCutoff,
                            refreshing = false,
                        )
                    }
                }
            }
    }

    private fun syncFeedsThenRead() {
        viewModelScope.launch {
            runCatching { syncFeeds() }.onFailure { if (it is CancellationException) throw it }
            readFeed()
        }
    }

    /**
     * Reads the feed half from the store: again from the top, as many rows
     * as are on screen, or with [more] the page after them.
     */
    private suspend fun readFeed(more: Boolean = false) {
        val current = mutableState.value
        val offset = if (more) current.feed.size else 0
        val limit = if (more) FlaggedList.FEED_PAGE_SIZE else maxOf(current.feed.size, FlaggedList.FEED_PAGE_SIZE)
        val query = ItemQuery(scope = RssItemScope.All, limit = limit, offset = offset, flag = current.criterion)
        val rows = runCatching { store.items(query) }.getOrNull() ?: return
        val titles =
            runCatching { store.subscriptions().associate { it.subscriptionId to it.displayTitle } }
                .getOrDefault(current.subscriptionTitles)
        // A pick made while the store was being read asked for another list.
        if (mutableState.value.criterion != current.criterion) return
        mutableState.update { state ->
            state.copy(
                feed = if (more) state.feed + rows.filterNot { row -> state.feed.any { it.id == row.id } } else rows,
                feedHasMore = rows.size == limit,
                feedLoaded = true,
                subscriptionTitles = titles,
            )
        }
        refreshPendingMarks()
    }

    // ------------------------------------------------------------ mail rows

    fun toggleSeen(envelope: Envelope) {
        setMailFlag(envelope, SEEN, !envelope.isSeen)
    }

    /** Sets or clears one flag on a message by its slot, in the message's own folder. */
    fun setMailFlag(
        envelope: Envelope,
        flag: String,
        value: Boolean,
    ) {
        val folder = envelope.folder ?: return
        val flags =
            if (value) {
                (envelope.flags + flag).distinct()
            } else {
                envelope.flags.filterNot { it.equals(flag, ignoreCase = true) }
            }
        val patched = envelope.copy(flags = flags)
        patchMailFlags(folder, setOf(envelope.id), flag, value)
        viewModelScope.launch {
            try {
                mail.setFlag(folder, patched, flag, value)
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = userMessage(exception, "Could not update flags")) }
                loadMail(reset = true)
            }
        }
    }

    /**
     * The dispose a row's swipe asks for, resolved against the row's own
     * folder: archive or trash, back to the inbox from Archive, or (after
     * the screen's confirmation) deleted for good from Trash.
     */
    fun dispose(envelope: Envelope) {
        val ref = envelope.ref() ?: return
        val target = DisposeIntent.standard(preferences.value.disposeAction, ref.folder).moveTarget
        if (!disposing.add(ref)) return
        dropMail(ref.folder, setOf(ref.uid))
        viewModelScope.launch {
            try {
                if (target == null) {
                    mail.purge(ref.folder, ref.uid)
                } else {
                    mail.move(ref.folder, ref.uid, target.destination, target.markSeen)
                }
            } catch (exception: Exception) {
                if (exception is CancellationException) throw exception
                mutableState.update { it.copy(error = userMessage(exception, "Could not move message")) }
                loadMail(reset = true)
            } finally {
                disposing.remove(ref)
            }
        }
    }

    private fun patchMailFlags(
        folder: String,
        uids: Set<Long>,
        flag: String,
        value: Boolean,
    ) {
        mutableState.update { state ->
            state.copy(
                mail =
                    state.mail.map { envelope ->
                        if (envelope.folder != folder || envelope.id !in uids) {
                            envelope
                        } else if (value) {
                            envelope.copy(flags = (envelope.flags + flag).distinct())
                        } else {
                            envelope.copy(flags = envelope.flags.filterNot { it.equals(flag, ignoreCase = true) })
                        }
                    },
            )
        }
    }

    private fun dropMail(
        folder: String,
        uids: Set<Long>,
    ) {
        mutableState.update { state ->
            state.copy(mail = state.mail.filterNot { it.folder == folder && it.id in uids })
        }
    }

    // ------------------------------------------------------------ feed rows

    fun setRead(
        item: RssItem,
        isRead: Boolean,
    ) {
        val changed = item.copy(isRead = isRead, isReadExplicit = true)
        patchFeed(changed)
        viewModelScope.launch {
            runCatching { engine().setRead(item, isRead) }
            feedEvents.post(FeedEvent.ItemChanged(changed))
            refreshPendingMarks()
        }
    }

    /**
     * Sets or clears one flag of Settings > Flags on a feed item. Shown at
     * once, then written and sent; afterwards the row is what the store
     * holds, because the server can refuse a flag it no longer lists and
     * the queue then takes it off the item again.
     */
    fun setFeedFlag(
        item: RssItem,
        slot: String,
        isSet: Boolean,
    ) {
        val changed = item.withFlag(slot, isSet)
        patchFeed(changed)
        viewModelScope.launch {
            runCatching { engine().setPaletteFlag(item, slot, isSet) }
            val stored = runCatching { store.item(item.feedId, item.sortKey) }.getOrNull() ?: changed
            patchFeed(stored)
            feedEvents.post(FeedEvent.ItemChanged(stored))
            refreshPendingMarks()
        }
    }

    /** Opening an item marks it read when the feed reader's own preference says so. */
    fun didOpen(item: RssItem) {
        if (preferences.value.effectiveRssMarkAsRead != MarkAsRead.ON_OPEN || item.isRead) return
        setRead(item, true)
    }

    /** Patches one row in place; one that stops matching the pick stays until the half is next read. */
    private fun patchFeed(changed: RssItem) {
        mutableState.update { state ->
            state.copy(
                feed =
                    state.feed.map {
                        if (it.id == changed.id) {
                            it.copy(isRead = changed.isRead, isFavorite = changed.isFavorite, flags = changed.flags)
                        } else {
                            it
                        }
                    },
            )
        }
    }

    private suspend fun refreshPendingMarks() {
        val pending =
            mutableState.value.feed
                .filter { runCatching { store.hasPending(it.feedId, it.sortKey) }.getOrDefault(false) }
                .map { it.id }
                .toSet()
        mutableState.update { it.copy(pendingIds = pending) }
    }

    companion object {
        private const val SEEN = "\\Seen"

        /**
         * A page appended to what is loaded, less any message already
         * there: the server's cursor is by day, so a page boundary that
         * shifts under mailbox churn can deliver a row twice, and a
         * duplicate would also be a duplicate key for the list.
         */
        internal fun appendPage(
            loaded: List<Envelope>,
            page: List<Envelope>,
        ): List<Envelope> {
            val known = loaded.mapNotNullTo(mutableSetOf()) { it.ref() }
            return loaded + page.filterNot { it.ref() in known }
        }

        fun factory(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    FlaggedViewModel(
                        mail = ContainerFlaggedMail(container),
                        store = container.rssStore,
                        engine = { container.requireRssSync() },
                        syncFeeds = {
                            val engine = container.requireRssSync()
                            // The catalog first and on its own, as the Feeds
                            // screen does it: a subscription that has gone
                            // takes its web profile with it.
                            val diff = engine.refreshCatalog()
                            FeedWebProfiles.drop(container.applicationContext, diff.removedDataStoreUuids)
                            engine.syncAll()
                            container.feedEvents.post(FeedEvent.Changed)
                        },
                        feedEvents = container.feedEvents,
                        mailEvents = container.mailEvents.events,
                        preferences = container.preferences.preferences,
                    )
                }
            }
    }
}
