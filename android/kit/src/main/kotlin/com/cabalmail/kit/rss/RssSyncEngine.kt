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
import com.cabalmail.kit.settings.FlagPalette
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
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
 *     the feed's state sync: the read and favorite marks and the flags
 *     changed on the server (by another device, or by a mark-all-read's
 *     flip) since the feed's state cursor, applied to the cached items. Without it a mark made
 *     elsewhere never arrives, because ingest time does not move when
 *     state does.
 *   * [drainPending] — the offline mutation queue, replayed in the order
 *     the user made the changes: item marks coalesced into
 *     `/rss_set_item_state` batches, each `/rss_mark_all_read` a fence
 *     between batches. A failure leaves the queue intact for the next
 *     attempt, with one exception: a flag add the server refuses because
 *     the account's flag list does not hold that flag would be refused
 *     every time, and the whole batch with it, so once this device owes
 *     the server no change to the flag list those adds are dropped and the
 *     rest of the batch is sent again ([pushItemStates]).
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

    /**
     * Sends the change to the flag list this device owes the server, if
     * any, and says how that went. Asked before a refused flag add is
     * dropped ([pushItemStates]); the app installs it when it builds the
     * engine, and the kit's feed code knows nothing else of settings. With
     * none installed the answer is [RssUnsentSettings.NOTHING_UNSENT].
     */
    @Volatile
    var unsentSettingsPush: (suspend () -> RssUnsentSettings)? = null

    /** One drain at a time, so the server sees an item's changes in the order they were made. */
    private val draining = Mutex()

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
            // The first page is the one time a sync owns the older cursor —
            // the feed had none. Written here rather than at the end so a
            // load-older starting during the rest of the run wins (#1955).
            store.setOlderCursor(subscription.feedId, state.olderCursor, state.olderExhausted)
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
        // Only the half this run owns: a "Load older items" may have moved
        // the older cursor since the row was read at :71 (#1955).
        store.setSyncCursors(subscription.feedId, state.sinceCursor, state.stateCursor, state.lastSyncedAt)
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
        // Only the older half: a sync running alongside owns the rest.
        store.setOlderCursor(subscription.feedId, page.nextCursor.orEmpty(), page.nextCursor == null)
        return page.items.size
    }

    /**
     * Catalog, then every subscription, [concurrency] at a time; then the
     * pending queue. Per-feed failures are not fatal; a catalog failure
     * ends the run. The three kinds are reported separately so a caller
     * can tell "every feed failed" from "one push failed" (#1954).
     */
    suspend fun syncAll(): RssSyncReport {
        try {
            refreshCatalog()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            return RssSyncReport(catalogFailure = exception)
        }
        val subs = runCatching { store.subscriptions() }.getOrDefault(emptyList())
        val feedFailures = LinkedHashMap<String, Throwable>()
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
                .forEach { (id, error) -> feedFailures[id] = error }
        }
        var pendingFailure: Throwable? = null
        try {
            drainPending()
        } catch (exception: Exception) {
            if (exception is CancellationException) throw exception
            pendingFailure = exception
        }
        return RssSyncReport(
            subscriptionIds = subs.map { it.subscriptionId },
            feedFailures = feedFailures,
            pendingFailure = pendingFailure,
        )
    }

    // --------------------------------------------------- pending mutations

    /** One server call of a drain, in queue order. */
    private sealed class DrainStep {
        /** The queue rows of at most [STATE_BATCH] items, sent as one change an item. */
        data class ItemStates(
            val rows: List<PendingMutation>,
        ) : DrainStep()

        data class MarkAllRead(
            val mutation: PendingMutation,
        ) : DrainStep()
    }

    /**
     * Pushes queued state changes. Returns how many queue rows were cleared.
     * A drain asked for while another is pushing waits and then reads the
     * queue afresh: two at once could reach the server out of order, and
     * the later intent for an item (a flag set, then cleared) would lose.
     */
    suspend fun drainPending(): Int =
        draining.withLock {
            val pending = store.pendingMutations()
            var cleared = 0
            for (step in drainSteps(pending)) {
                when (step) {
                    is DrainStep.ItemStates -> cleared += pushItemStates(step.rows)
                    is DrainStep.MarkAllRead -> {
                        val result = client.markAllRead(RssItemScope.Subscription(step.mutation.subscriptionId))
                        store.applyServerWatermark(step.mutation.subscriptionId, result.readWatermark)
                        store.deletePending(listOf(step.mutation.id))
                        cleared += 1
                    }
                }
            }
            cleared
        }

    /**
     * Sends one batch and clears its rows from the queue; returns how many
     * rows left it.
     *
     * The server checks every flag a call adds against the account's flag
     * list before it writes anything, and refuses the whole call for one
     * the list does not hold ([RssFlagRefusal]). Two things leave such an
     * add in the queue. The flag was deleted, here or on another device,
     * after the change was queued, and asking again cannot succeed. Or the
     * flag was created on this device and the settings that carry it have
     * not reached the server yet. So the first refusal of a batch asks for
     * the owed settings to be sent ([unsentSettingsPush]), and the answer
     * decides:
     *   * sent: the batch goes again as it was, and a refusal after that
     *     is final, since the server's flag list is now this device's;
     *   * still unsent: the refused adds stay queued for a later drain and
     *     the rest of the batch goes now, because the refusal would
     *     otherwise hold every other change with it;
     *   * nothing unsent: the refused adds are taken back
     *     ([RssStore.dropRefusedFlagAdds]) and the rest of the batch goes.
     * Every round after the first takes at least one row out, so this ends.
     */
    private suspend fun pushItemStates(batch: List<PendingMutation>): Int {
        var rows = batch
        var cleared = 0
        var asked: RssUnsentSettings? = null
        while (rows.isNotEmpty()) {
            val refusal =
                try {
                    client.setItemState(stateChanges(rows))
                    break
                } catch (refusal: RssFlagRefusal) {
                    refusal
                }
            val refused = rows.filter { it.kind == PendingKind.FLAG && it.value && it.slot in refusal.slots }
            // Slots this batch does not add: not something dropping a row
            // here can answer, so the queue stays as any failure leaves it.
            if (refused.isEmpty()) throw refusal.asApiError()
            val settings =
                when (asked) {
                    null -> (unsentSettingsPush?.invoke() ?: RssUnsentSettings.NOTHING_UNSENT).also { asked = it }
                    RssUnsentSettings.SENT -> RssUnsentSettings.NOTHING_UNSENT
                    else -> asked
                }
            when (settings) {
                RssUnsentSettings.SENT -> Unit
                RssUnsentSettings.STILL_UNSENT -> rows = rows - refused.toSet()
                RssUnsentSettings.NOTHING_UNSENT -> {
                    // Fewer than `refused` when the user has changed one of
                    // them again since this drain read the queue: that row
                    // is gone and the newer change waits for the next drain.
                    cleared += store.dropRefusedFlagAdds(refused.map { it.id })
                    rows = rows - refused.toSet()
                }
            }
        }
        store.deletePending(rows.map { it.id })
        return cleared + rows.size
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

    /**
     * Sets or clears one flag of the user's own, by its palette slot
     * ([FlagPalette.SLOTS]). The built-in flag is [setFavorite]; that slot,
     * or anything else that is not a keyword slot, is refused here, because
     * the server refuses it too and nothing could then clear the row from
     * the queue.
     */
    suspend fun setFlag(
        item: RssItem,
        slot: String,
        isSet: Boolean,
    ) {
        require(slot in FlagPalette.SLOTS) { "Not a flag slot: $slot" }
        store.setFlag(item.feedId, item.sortKey, slot, isSet)
        pushSoon()
    }

    /**
     * Sets or clears the flag in palette slot [slot] on an item, whichever
     * kind it is: the built-in flag's slot is the favorite mark
     * ([setFavorite]), any other a flag of the user's own ([setFlag]). The
     * one place that difference is told apart for a write, as
     * [RssItem.carries] is for a read.
     */
    suspend fun setPaletteFlag(
        item: RssItem,
        slot: String,
        isSet: Boolean,
    ) = if (slot == FlagPalette.SYSTEM_SLOT) setFavorite(item, isSet) else setFlag(item, slot, isSet)

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
         * coalesce (the queue holds one row per item and kind, and per slot
         * for a flag change, so every change to one item becomes one entry)
         * into batches of at most [STATE_BATCH] items; a mark-all-read is a
         * fence. The user's order is what the server must see: replaying
         * "mark all read, then mark X unread" the other way round lets the
         * server's mark-all-read flip X back.
         */
        private fun drainSteps(pending: List<PendingMutation>): List<DrainStep> {
            val steps = ArrayList<DrainStep>()
            var rows = LinkedHashMap<String, MutableList<PendingMutation>>()

            fun closeBatch() {
                rows.keys.sorted().chunked(STATE_BATCH).forEach { batch ->
                    steps += DrainStep.ItemStates(batch.flatMap { rows.getValue(it) })
                }
                rows = LinkedHashMap()
            }
            for (mutation in pending) {
                if (mutation.kind == PendingKind.MARK_ALL_READ) {
                    closeBatch()
                    steps += DrainStep.MarkAllRead(mutation)
                    continue
                }
                rows.getOrPut("${mutation.feedId}#${mutation.sortKey}") { mutableListOf() }.add(mutation)
            }
            closeBatch()
            return steps
        }

        /**
         * One entry an item for a batch's rows, in item order: its read and
         * favorite marks and the flags it adds and removes.
         */
        internal fun stateChanges(rows: List<PendingMutation>): List<RssItemStateChange> {
            val changes = LinkedHashMap<String, RssItemStateChange>()
            for (row in rows) {
                val key = "${row.feedId}#${row.sortKey}"
                val change = changes[key] ?: RssItemStateChange(row.feedId, row.sortKey)
                changes[key] =
                    when (row.kind) {
                        PendingKind.READ -> change.copy(isRead = row.value)
                        PendingKind.FAVORITE -> change.copy(isFavorite = row.value)
                        // The queue holds one row per item and slot; were
                        // there two, the later one is the intent, and a slot
                        // never goes in both lists, which the server refuses.
                        PendingKind.FLAG ->
                            if (row.value) {
                                change.copy(
                                    addFlags = change.addFlags + row.slot,
                                    removeFlags =
                                        change.removeFlags - row.slot,
                                )
                            } else {
                                change.copy(
                                    addFlags = change.addFlags - row.slot,
                                    removeFlags =
                                        change.removeFlags + row.slot,
                                )
                            }
                        PendingKind.MARK_ALL_READ -> change
                    }
            }
            return changes.keys.sorted().map { changes.getValue(it) }
        }
    }
}
