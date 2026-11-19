package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderDeleteResult
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemOrder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssItemsPage
import com.cabalmail.kit.models.RssMarkAllReadResult
import com.cabalmail.kit.models.RssOpmlExport
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult
import kotlinx.coroutines.CompletableDeferred

/**
 * The item-state half of the feed API as the server keeps it
 * (`docs/rss.md`, `/rss_set_item_state` and the state sync), for the flag
 * tests: one account's state rows and its flag list. Where a scripted
 * client replays canned pages, this one answers from what it holds, so two
 * devices can write to it and read each other's changes back.
 *
 * - `setItemState` checks every slot a call adds against [palette] before
 *   it writes anything and refuses the whole call for one it does not hold
 *   ([RssFlagRefusal], naming the refused slots, sorted). A slot in both
 *   lists of one entry is refused too. Otherwise each entry's marks are
 *   written, and its flags added and removed.
 * - `syncItemStates` answers every row written since the cursor it is
 *   given (a count of writes), flags included.
 *
 * Everything else a sync touches is empty; the rest is unused.
 */
class FakeRssServer : RssClient {
    /** The slots of the account's flag list. */
    val palette = mutableSetOf<String>()

    /**
     * Where the flag list is read from at each call: [palette], unless a
     * test points it at the settings row another fake holds.
     */
    var paletteSource: () -> Set<String> = { palette }

    /** One state row, as the server holds it. */
    data class Row(
        val feedId: String,
        val sortKey: String,
        val isRead: Boolean = false,
        val isFavorite: Boolean = false,
        val flags: Set<String> = emptySet(),
        /** The write that last touched the row: the state sync's cursor. */
        val written: Int = 0,
    )

    val rows = LinkedHashMap<String, Row>()
    private var writes = 0

    /** Every `setItemState` call that arrived, however it was answered. */
    val calls = mutableListOf<List<RssItemStateChange>>()

    /** How each call went, in order: `ok`, `refused`, `failed`. */
    val outcomes = mutableListOf<String>()

    /** Makes every `setItemState` fail as an unreachable server does. */
    var failure: Throwable? = null

    /** Parks the next `setItemState` inside its call until completed. */
    var gate: CompletableDeferred<Unit>? = null
    val gateReached = CompletableDeferred<Unit>()

    fun flagsOf(item: RssItem): Set<String> = rows[item.id]?.flags.orEmpty()

    override suspend fun setItemState(changes: List<RssItemStateChange>): Int {
        calls += changes
        gate?.let { parked ->
            gate = null
            gateReached.complete(Unit)
            parked.await()
        }
        failure?.let {
            outcomes += "failed"
            throw it
        }
        require(changes.size <= RssSyncEngine.STATE_BATCH) { "more than ${RssSyncEngine.STATE_BATCH} items in a call" }
        val both = changes.flatMap { it.addFlags intersect it.removeFlags }
        check(both.isEmpty()) { "a slot in both lists: $both" }
        val refused = changes.flatMap { it.addFlags }.toSet() - paletteSource()
        if (refused.isNotEmpty()) {
            outcomes += "refused"
            throw RssFlagRefusal(refused, "Not a flag in the palette: ${refused.sorted().joinToString(", ")}.")
        }
        writes += 1
        for (change in changes) {
            val key = "${change.feedId}#${change.sortKey}"
            val row = rows[key] ?: Row(change.feedId, change.sortKey)
            rows[key] =
                row.copy(
                    isRead = change.isRead ?: row.isRead,
                    isFavorite = change.isFavorite ?: row.isFavorite,
                    flags = row.flags + change.addFlags - change.removeFlags,
                    written = writes,
                )
        }
        outcomes += "ok"
        return changes.size
    }

    override suspend fun syncItemStates(
        subscriptionId: String,
        since: String,
        limit: Int,
    ): RssStateSyncPage {
        val after = since.toIntOrNull() ?: 0
        return RssStateSyncPage(
            states =
                rows.values.filter { it.written > after }.map {
                    RssItemState(
                        feedId = it.feedId,
                        sortKey = it.sortKey,
                        isRead = it.isRead,
                        isReadExplicit = true,
                        isFavorite = it.isFavorite,
                        flags = it.flags,
                    )
                },
            nextSince = writes.toString(),
            hasMore = false,
        )
    }

    override suspend fun syncItems(
        subscriptionId: String,
        since: String,
        limit: Int,
    ): RssSyncPage = RssSyncPage()

    override suspend fun listItems(
        scope: RssItemScope,
        filter: RssItemFilter,
        order: RssItemOrder,
        limit: Int,
        cursor: String?,
    ): RssItemsPage = RssItemsPage()

    override suspend fun listSubscriptions(): RssCatalog = error("unused")

    override suspend fun markAllRead(scope: RssItemScope): RssMarkAllReadResult = error("unused")

    override suspend fun updateSubscription(
        subscriptionId: String,
        update: RssSubscriptionUpdate,
    ): RssSubscription = error("unused")

    override suspend fun updateRssFolder(
        folderId: String,
        update: RssFolderUpdate,
    ): RssFolder = error("unused")

    override suspend fun subscribe(
        url: String,
        folderId: String?,
    ): RssSubscribeResult = error("unused")

    override suspend fun unsubscribe(subscriptionId: String): RssUnsubscribeResult = error("unused")

    override suspend fun newRssFolder(
        name: String,
        parentFolderId: String?,
        displayOrder: Int?,
    ): RssFolder = error("unused")

    override suspend fun deleteRssFolder(folderId: String): RssFolderDeleteResult = error("unused")

    override suspend fun getItem(
        feedId: String,
        sortKey: String,
    ): RssItem = error("unused")

    override suspend fun importOpml(
        opml: String,
        folderId: String?,
    ): RssOpmlImportResult = error("unused")

    override suspend fun exportOpml(): RssOpmlExport = error("unused")
}
