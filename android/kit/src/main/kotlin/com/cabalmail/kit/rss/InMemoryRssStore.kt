package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssSubscription
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The [RssStore] contract in plain Kotlin collections, the reference the
 * kit tests (store and sync engine) run against; also a fine store for a
 * process that needs no persistence. Semantics mirror [RoomRssStore] and
 * the Apple store row for row: see the contract's documentation.
 */
class InMemoryRssStore(
    private val clock: () -> String = RssRules::isoNow,
) : RssStore {
    private class StoredItem(
        var item: RssItem,
        var bodyText: String,
        var isRead: Boolean,
        var isFavorite: Boolean,
        var stateIsExplicit: Boolean,
    )

    private val mutex = Mutex()
    private val folders = LinkedHashMap<String, RssFolder>()
    private val subscriptions = LinkedHashMap<String, RssSubscription>()
    private val items = LinkedHashMap<String, StoredItem>()
    private val syncStates = HashMap<String, FeedSyncState>()
    private val pending = ArrayList<PendingMutation>()
    private var nextPendingId = 1L

    override suspend fun clear() =
        mutex.withLock {
            pending.clear()
            syncStates.clear()
            items.clear()
            subscriptions.clear()
            folders.clear()
        }

    // ------------------------------------------------------------- catalog

    override suspend fun replaceCatalog(catalog: RssCatalog): CatalogDiff =
        mutex.withLock {
            val keep = catalog.subscriptions.map { it.subscriptionId }.toSet()
            val removed = subscriptions.values.filter { it.subscriptionId !in keep }
            val keptFeeds = catalog.subscriptions.map { it.feedId }.toSet()
            val removedFeeds = removed.map { it.feedId }.toSet() - keptFeeds
            removed.forEach { subscriptions.remove(it.subscriptionId) }
            removedFeeds.forEach { deleteFeedRows(it) }
            catalog.subscriptions.forEach { upsertSubscriptionLocked(it) }
            val folderIds = catalog.folders.map { it.folderId }.toSet()
            folders.keys.retainAll(folderIds)
            catalog.folders.forEach { folders[it.folderId] = it }
            CatalogDiff(
                removedSubscriptionIds = removed.map { it.subscriptionId },
                removedDataStoreUuids = removed.map { it.dataStoreUuid }.filter { it.isNotEmpty() },
                removedFeedIds = removedFeeds.sorted(),
            )
        }

    override suspend fun upsertSubscription(subscription: RssSubscription) =
        mutex.withLock { upsertSubscriptionLocked(subscription) }

    private fun upsertSubscriptionLocked(subscription: RssSubscription) {
        val existing = subscriptions[subscription.subscriptionId]
        subscriptions[subscription.subscriptionId] =
            if (existing == null) {
                subscription
            } else {
                subscription.copy(
                    readWatermark = maxOf(existing.readWatermark, subscription.readWatermark),
                    feed = subscription.feed ?: existing.feed,
                )
            }
    }

    override suspend fun upsertFolder(folder: RssFolder) = mutex.withLock { folders[folder.folderId] = folder }

    override suspend fun folders(): List<RssFolder> = mutex.withLock { foldersLocked() }

    private fun foldersLocked(): List<RssFolder> =
        folders.values.sortedWith(compareBy({ it.displayOrder }, { it.name }))

    override suspend fun folder(id: String): RssFolder? = mutex.withLock { folders[id] }

    override suspend fun subscriptions(): List<RssSubscription> = mutex.withLock { subscriptionsLocked() }

    private fun subscriptionsLocked(): List<RssSubscription> = subscriptions.values.sortedBy { it.subscriptionId }

    override suspend fun subscription(id: String): RssSubscription? = mutex.withLock { subscriptions[id] }

    override suspend fun feedIds(scope: RssItemScope): List<String> = mutex.withLock { feedIdsLocked(scope) }

    private fun feedIdsLocked(scope: RssItemScope): List<String> {
        val subs = subscriptionsLocked()
        return when (scope) {
            RssItemScope.All -> subs.map { it.feedId }.toSet().sorted()
            is RssItemScope.Subscription -> listOfNotNull(subscriptions[scope.subscriptionId]?.feedId)
            is RssItemScope.Folder -> {
                val wanted = descendantFolderIds(scope.folderId)
                subs
                    .filter { it.folderId in wanted }
                    .map { it.feedId }
                    .toSet()
                    .sorted()
            }
        }
    }

    private fun descendantFolderIds(folderId: String): Set<String> {
        val byParent = foldersLocked().groupBy { it.parentFolderId }
        val wanted = mutableSetOf(folderId)
        val frontier = ArrayDeque(listOf(folderId))
        while (frontier.isNotEmpty()) {
            val current = frontier.removeLast()
            byParent[current].orEmpty().forEach { child ->
                if (wanted.add(child.folderId)) frontier.addLast(child.folderId)
            }
        }
        return wanted
    }

    private fun deleteFeedRows(feedId: String) {
        items.values.removeAll { it.item.feedId == feedId }
        syncStates.remove(feedId)
        pending.removeAll { it.feedId == feedId }
    }

    // --------------------------------------------------------------- items

    override suspend fun upsertItems(items: List<RssItem>) =
        mutex.withLock {
            val shielded =
                pending
                    .filter { it.kind == PendingKind.READ || it.kind == PendingKind.FAVORITE }
                    .map { "${it.feedId}#${it.sortKey}" }
                    .toSet()
            for (item in items) {
                val existing = this.items[item.id]
                val keepLocalState = item.id in shielded && existing != null
                this.items[item.id] =
                    StoredItem(
                        item = item,
                        bodyText = RssRules.bodyText(item.bodyHtml),
                        isRead = if (keepLocalState) existing.isRead else item.isRead,
                        isFavorite = if (keepLocalState) existing.isFavorite else item.isFavorite,
                        stateIsExplicit = if (keepLocalState) existing.stateIsExplicit else item.isReadExplicit,
                    )
            }
        }

    override suspend fun items(query: ItemQuery): List<RssItem> =
        mutex.withLock {
            val feedIds = feedIdsLocked(query.scope).toSet()
            if (feedIds.isEmpty()) return@withLock emptyList()
            items.values
                .asSequence()
                .filter { it.item.feedId in feedIds }
                .map { project(it) }
                .filter { projected ->
                    when (query.filter) {
                        RssItemFilter.ALL -> true
                        RssItemFilter.UNREAD -> !projected.isRead
                        RssItemFilter.FAVORITE -> projected.isFavorite
                    }
                }.sortedWith(RssRules.comparator(query.ordering))
                .drop(query.offset)
                .take(query.limit)
                .toList()
        }

    override suspend fun item(
        feedId: String,
        sortKey: String,
    ): RssItem? = mutex.withLock { items["$feedId#$sortKey"]?.let { project(it) } }

    override suspend fun unreadCounts(): Map<String, Int> =
        mutex.withLock {
            val counts = HashMap<String, Int>()
            for (stored in items.values) {
                if (project(stored).isRead) continue
                subscriptionsLocked().filter { it.feedId == stored.item.feedId }.forEach {
                    counts[it.subscriptionId] = (counts[it.subscriptionId] ?: 0) + 1
                }
            }
            counts
        }

    override suspend fun totalCounts(): Map<String, Int> =
        mutex.withLock {
            val counts = HashMap<String, Int>()
            for (stored in items.values) {
                subscriptionsLocked().filter { it.feedId == stored.item.feedId }.forEach {
                    counts[it.subscriptionId] = (counts[it.subscriptionId] ?: 0) + 1
                }
            }
            counts
        }

    override suspend fun search(
        feedId: String,
        query: String,
        limit: Int,
    ): List<RssItem> =
        mutex.withLock {
            val tokens = RssRules.searchTokens(query)
            if (tokens.isEmpty()) return@withLock emptyList()
            items.values
                .asSequence()
                .filter { it.item.feedId == feedId }
                .filter { stored ->
                    val words = RssRules.searchTokens(stored.item.title + " " + stored.bodyText)
                    tokens.all { token -> words.any { it.startsWith(token) } }
                }.map { project(it) }
                .sortedByDescending { it.publishedAt }
                .take(limit)
                .toList()
        }

    override suspend fun itemCount(feedId: String): Int =
        mutex.withLock { items.values.count { it.item.feedId == feedId } }

    /** The watermark of the feed's subscription (the first by id when two share a feed). */
    private fun watermarkFor(feedId: String): String =
        subscriptionsLocked().firstOrNull { it.feedId == feedId }?.readWatermark.orEmpty()

    private fun subscriptionIdFor(feedId: String): String =
        subscriptionsLocked().firstOrNull { it.feedId == feedId }?.subscriptionId.orEmpty()

    private fun hasPendingLocked(
        kind: PendingKind,
        feedId: String,
        sortKey: String,
    ): Boolean = pending.any { it.kind == kind && it.feedId == feedId && it.sortKey == sortKey }

    private fun project(stored: StoredItem): RssItem =
        stored.item.copy(
            subscriptionId = subscriptionIdFor(stored.item.feedId),
            isRead =
                RssRules.isRead(
                    isRead = stored.isRead,
                    stateIsExplicit = stored.stateIsExplicit,
                    publishedAt = stored.item.publishedAt,
                    watermark = watermarkFor(stored.item.feedId),
                ),
            isReadExplicit = stored.stateIsExplicit,
            isFavorite = stored.isFavorite,
        )

    // --------------------------------------------------------- local state

    override suspend fun setRead(
        feedId: String,
        sortKey: String,
        isRead: Boolean,
    ) = mutex.withLock {
        items["$feedId#$sortKey"]?.let {
            it.isRead = isRead
            it.stateIsExplicit = true
        }
        enqueue(PendingKind.READ, feedId, sortKey, isRead)
    }

    override suspend fun setFavorite(
        feedId: String,
        sortKey: String,
        isFavorite: Boolean,
    ) = mutex.withLock {
        items["$feedId#$sortKey"]?.isFavorite = isFavorite
        enqueue(PendingKind.FAVORITE, feedId, sortKey, isFavorite)
    }

    override suspend fun markAllRead(
        subscriptionId: String,
        watermark: String?,
    ) = mutex.withLock {
        val mark = watermark ?: clock()
        val sub = subscriptions[subscriptionId] ?: return@withLock
        subscriptions[subscriptionId] = sub.copy(readWatermark = maxOf(sub.readWatermark, mark))
        items.values
            .filter { it.item.feedId == sub.feedId && it.stateIsExplicit && !it.isRead && it.item.publishedAt <= mark }
            .forEach { it.isRead = true }
        pending +=
            PendingMutation(
                id = nextPendingId++,
                kind = PendingKind.MARK_ALL_READ,
                feedId = sub.feedId,
                sortKey = "",
                subscriptionId = subscriptionId,
                value = false,
            )
    }

    override suspend fun applyServerStates(states: List<RssItemState>) =
        mutex.withLock {
            for (state in states) {
                val stored = items["${state.feedId}#${state.sortKey}"] ?: continue
                if (!hasPendingLocked(PendingKind.READ, state.feedId, state.sortKey)) {
                    stored.isRead = state.isRead
                    stored.stateIsExplicit = state.isReadExplicit
                }
                if (!hasPendingLocked(PendingKind.FAVORITE, state.feedId, state.sortKey)) {
                    stored.isFavorite = state.isFavorite
                }
            }
        }

    override suspend fun applyServerWatermark(
        subscriptionId: String,
        watermark: String,
    ) = mutex.withLock {
        subscriptions[subscriptionId]?.let {
            subscriptions[subscriptionId] = it.copy(readWatermark = maxOf(it.readWatermark, watermark))
        }
        Unit
    }

    override suspend fun pendingMutations(): List<PendingMutation> = mutex.withLock { pending.toList() }

    override suspend fun pendingCount(): Int = mutex.withLock { pending.size }

    override suspend fun hasPending(
        feedId: String,
        sortKey: String,
    ): Boolean = mutex.withLock { pending.any { it.feedId == feedId && it.sortKey == sortKey } }

    override suspend fun deletePending(ids: List<Long>) =
        mutex.withLock {
            val gone = ids.toSet()
            pending.removeAll { it.id in gone }
            Unit
        }

    private fun enqueue(
        kind: PendingKind,
        feedId: String,
        sortKey: String,
        value: Boolean,
    ) {
        // The latest intent for an item wins; drop earlier queued flips of
        // the same kind so a drain never replays a superseded state.
        pending.removeAll { it.kind == kind && it.feedId == feedId && it.sortKey == sortKey }
        pending += PendingMutation(nextPendingId++, kind, feedId, sortKey, subscriptionId = "", value = value)
    }

    // -------------------------------------------------------- sync cursors

    override suspend fun syncState(feedId: String): FeedSyncState =
        mutex.withLock { syncStates[feedId] ?: FeedSyncState() }

    override suspend fun setSyncState(
        feedId: String,
        state: FeedSyncState,
    ) = mutex.withLock { syncStates[feedId] = state }
}
