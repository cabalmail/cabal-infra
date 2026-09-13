package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemOrder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * Keeps an [RssStore] current with the server and pushes the user's local
 * state changes back — the Kotlin sibling of the Apple kit's
 * `RssSyncEngine`, step for step (rss plan, phase 6).
 *
 * Three jobs, all idempotent and safe to overlap:
 *   * [refreshCatalog] — folders and subscriptions from the server; the
 *     store deletes what departed and reports it so the app can drop the
 *     matching web-view profile.
 *   * [syncItems] — a feed's items. A feed with no cursor yet is populated
 *     newest-first ([initialPageSize] items) and its cursor set to the
 *     largest `fetchedKey` seen; after that it follows the server's
 *     since-sync (ingest-time cursor) in pages until `hasMore` is false,
 *     bounded per run so one huge feed cannot monopolise a refresh. Then
 *     the feed's state sync: the read/favorite marks changed on the server
 *     (by another device, or by a mark-all-read's flip) since the feed's
 *     state cursor, applied to the cached items. Without it a mark made
 *     elsewhere never arrives, because ingest time does not move when
 *     state does.
 *   * [drainPending] — the offline mutation queue, replayed in the order
 *     the user made the changes: item marks coalesced into
 *     `/rss_set_item_state` batches, each `/rss_mark_all_read` a fence
 *     between batches. A failure leaves the queue intact for the next
 *     attempt.
 *
 * The engine never decides *when* to run; the app calls it from its
 * triggers (selection, foreground, periodic refresh, reconnect).
 */
class RssSyncEngine(
    val client: RssClient,
    val store: RssStore,
) {
    /** Items fetched for a subscription with no sync history. */
    var initialPageSize = 100

    /** Page size for since-sync and "load older". */
    var pageSize = 100

    /** Since-sync (and state-sync) pages per feed per run. */
    var maxPagesPerRun = 5

    /** Feeds synced at once by [syncAll]. */
    var concurrency = 4

    // ------------------------------------------------------------- catalog

    suspend fun refreshCatalog(): CatalogDiff = store.replaceCatalog(client.listSubscriptions())

    // --------------------------------------------------------------- items

    /** Syncs one subscription's items; returns how many the store received. */
    suspend fun syncItems(subscription: RssSubscription): Int {
        var state = store.syncState(subscription.feedId)
        var received = 0
        if (state.sinceCursor.isEmpty()) {
            val page =
                client.listItems(
                    scope = RssItemScope.Subscription(subscription.subscriptionId),
                    filter = RssItemFilter.ALL,
                    order = RssItemOrder.NEWEST,
                    limit = initialPageSize,
                    cursor = null,
                )
            store.upsertItems(page.items)
            received += page.items.size
            state =
                state.copy(
                    // The page is newest-first by sort key, which need not match
                    // ingest order: take the largest key, not the last item's.
                    sinceCursor = page.items.maxOfOrNull { it.fetchedKey } ?: SENTINEL_CURSOR,
                    olderCursor = page.nextCursor.orEmpty(),
                    olderExhausted = page.nextCursor == null,
                )
        }
        var pages = 0
        var since = if (state.sinceCursor == SENTINEL_CURSOR) "" else state.sinceCursor
        while (pages < maxPagesPerRun) {
            val page = client.syncItems(subscription.subscriptionId, since, pageSize)
            store.upsertItems(page.items)
            received += page.items.size
            pages += 1
            if (page.nextSince.isNotEmpty()) since = page.nextSince
            if (!page.hasMore) break
        }
        state = state.copy(sinceCursor = since.ifEmpty { SENTINEL_CURSOR })
        pages = 0
        var stateCursor = state.stateCursor
        while (pages < maxPagesPerRun) {
            val page = client.syncItemStates(subscription.subscriptionId, stateCursor, pageSize)
            store.applyServerStates(page.states)
            pages += 1
            if (page.nextSince.isNotEmpty()) stateCursor = page.nextSince
            if (!page.hasMore) break
        }
        state = state.copy(stateCursor = stateCursor, lastSyncedAt = RssRules.isoNow())
        store.setSyncState(subscription.feedId, state)
        return received
    }

    /**
     * Pulls the next page of older items for "Load older" / "Search older";
     * returns how many arrived (0 when the server has no more).
     */
    suspend fun loadOlder(subscription: RssSubscription): Int {
        val state = store.syncState(subscription.feedId)
        if (state.olderExhausted) return 0
        val page =
            client.listItems(
                scope = RssItemScope.Subscription(subscription.subscriptionId),
                filter = RssItemFilter.ALL,
                order = RssItemOrder.NEWEST,
                limit = pageSize,
                cursor = state.olderCursor.ifEmpty { null },
            )
        store.upsertItems(page.items)
        store.setSyncState(
            subscription.feedId,
            state.copy(olderCursor = page.nextCursor.orEmpty(), olderExhausted = page.nextCursor == null),
        )
        return page.items.size
    }

    /**
     * Catalog, then every subscription, [concurrency] at a time; then the
     * pending queue. Per-feed failures are collected under the subscription
     * id, not fatal; a catalog failure (`"catalog"`) ends the run, and a
     * drain failure is reported as `"pending"`. Empty means a clean run.
     */
    suspend fun syncAll(): Map<String, Throwable> {
        val failures = LinkedHashMap<String, Throwable>()
        try {
            refreshCatalog()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            failures["catalog"] = exception
            return failures
        }
        val subs = runCatching { store.subscriptions() }.getOrDefault(emptyList())
        val gate = Semaphore(concurrency)
        coroutineScope {
            subs
                .map { sub ->
                    async {
                        gate.withPermit {
                            try {
                                syncItems(sub)
                                null
                            } catch (exception: Exception) {
                                if (exception is CancellationException) throw exception
                                sub.subscriptionId to exception
                            }
                        }
                    }
                }.awaitAll()
                .filterNotNull()
                .forEach { (id, error) -> failures[id] = error }
        }
        try {
            drainPending()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            failures["pending"] = exception
        }
        return failures
    }

    // --------------------------------------------------- pending mutations

    /** One server call of a drain, in queue order. */
    private sealed class DrainStep {
        data class ItemStates(
            val changes: List<RssItemStateChange>,
            val pendingIds: List<Long>,
        ) : DrainStep()

        data class MarkAllRead(
            val mutation: PendingMutation,
        ) : DrainStep()
    }

    /** Pushes queued state changes. Returns how many queue rows were cleared. */
    suspend fun drainPending(): Int {
        val pending = store.pendingMutations()
        if (pending.isEmpty()) return 0
        var cleared = 0
        for (step in drainSteps(pending)) {
            when (step) {
                is DrainStep.ItemStates -> {
                    client.setItemState(step.changes)
                    store.deletePending(step.pendingIds)
                    cleared += step.pendingIds.size
                }
                is DrainStep.MarkAllRead -> {
                    val result = client.markAllRead(RssItemScope.Subscription(step.mutation.subscriptionId))
                    store.applyServerWatermark(step.mutation.subscriptionId, result.readWatermark)
                    store.deletePending(listOf(step.mutation.id))
                    cleared += 1
                }
            }
        }
        return cleared
    }

    // ----------------------------- local mutations (store first, then push)

    suspend fun setRead(
        item: RssItem,
        isRead: Boolean,
    ) {
        store.setRead(item.feedId, item.sortKey, isRead)
        pushSoon()
    }

    suspend fun setFavorite(
        item: RssItem,
        isFavorite: Boolean,
    ) {
        store.setFavorite(item.feedId, item.sortKey, isFavorite)
        pushSoon()
    }

    suspend fun markAllRead(subscriptionId: String) {
        store.markAllRead(subscriptionId)
        pushSoon()
    }

    /**
     * Changes a subscription's per-feed settings. The store takes the
     * change first, so the next item opened in the feed honours it even
     * while the round trip is in flight or offline; the server's copy
     * replaces it on success. A failure leaves the optimistic row for the
     * session — the next catalog refresh reconciles it — and rethrows so a
     * caller that cares can say so.
     */
    suspend fun updateSubscription(
        subscription: RssSubscription,
        update: RssSubscriptionUpdate,
    ): RssSubscription {
        if (update.isEmpty) return subscription
        store.upsertSubscription(subscription.applying(update))
        val updated = client.updateSubscription(subscription.subscriptionId, update)
        store.upsertSubscription(updated)
        return updated
    }

    /** Changes a folder's settings with the same optimistic shape as [updateSubscription]. */
    suspend fun updateFolder(
        folder: RssFolder,
        update: RssFolderUpdate,
    ): RssFolder {
        if (update.isEmpty) return folder
        store.upsertFolder(folder.applying(update))
        val updated = client.updateRssFolder(folder.folderId, update)
        store.upsertFolder(updated)
        return updated
    }

    /** One drain attempt; a failure (offline, say) is expected and leaves the queue for the next trigger. */
    private suspend fun pushSoon() {
        try {
            drainPending()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
        }
    }

    companion object {
        /**
         * Stored in place of an empty since-cursor once a feed has been
         * populated, so "never synced" and "synced, nothing ingested yet"
         * stay distinguishable. Real cursors are ISO timestamps, so a string
         * that cannot be one is safe.
         */
        const val SENTINEL_CURSOR = "~none"

        /** `/rss_set_item_state` accepts at most this many changes per call. */
        const val STATE_BATCH = 100

        /**
         * The queue as server calls. Item marks between two mark-all-reads
         * coalesce (the queue holds one row per item and kind, so read +
         * favorite for one item become one change) into batches of at most
         * [STATE_BATCH]; a mark-all-read is a fence. The user's order is what
         * the server must see: replaying "mark all read, then mark X unread"
         * the other way round lets the server's mark-all-read flip X back.
         */
        private fun drainSteps(pending: List<PendingMutation>): List<DrainStep> {
            val steps = ArrayList<DrainStep>()
            var changes = LinkedHashMap<String, RssItemStateChange>()
            var changeIds = LinkedHashMap<String, MutableList<Long>>()

            fun closeBatch() {
                val keys = changes.keys.sorted()
                keys.chunked(STATE_BATCH).forEach { batch ->
                    steps +=
                        DrainStep.ItemStates(
                            changes = batch.map { changes.getValue(it) },
                            pendingIds = batch.flatMap { changeIds[it].orEmpty() },
                        )
                }
                changes = LinkedHashMap()
                changeIds = LinkedHashMap()
            }
            for (mutation in pending) {
                if (mutation.kind == PendingKind.MARK_ALL_READ) {
                    closeBatch()
                    steps += DrainStep.MarkAllRead(mutation)
                    continue
                }
                val key = "${mutation.feedId}#${mutation.sortKey}"
                val change = changes[key] ?: RssItemStateChange(mutation.feedId, mutation.sortKey)
                changes[key] =
                    if (mutation.kind == PendingKind.READ) {
                        change.copy(isRead = mutation.value)
                    } else {
                        change.copy(isFavorite = mutation.value)
                    }
                changeIds.getOrPut(key) { mutableListOf() }.add(mutation.id)
            }
            closeBatch()
            return steps
        }
    }
}
