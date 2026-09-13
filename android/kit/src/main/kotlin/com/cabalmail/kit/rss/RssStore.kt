package com.cabalmail.kit.rss

import com.cabalmail.kit.compose.HtmlText
import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssSubscription
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * The on-device mirror of the user's RSS catalog and cached items, the
 * Kotlin sibling of the Apple kit's `RssStore` (rss plan, "Android-side
 * item cache"). The whole catalog is mirrored, not just items, so the feed
 * list renders offline; read state is computed locally by the same rule the
 * server uses ([RssRules.isRead]); every local mutation queues a row the
 * sync engine replays in order.
 *
 * Two implementations: [RoomRssStore] on device and [InMemoryRssStore] for
 * the JVM tests (Room's JVM story needs Robolectric, which the kit suite
 * deliberately avoids). The contract tests run against the in-memory store;
 * the Room store's SQL mirrors the Apple store's, which those same
 * assertions verified on real SQLite.
 */
interface RssStore {
    /** Drops every row (sign-out, or a corrupt-cache recovery). */
    suspend fun clear()

    /**
     * Replaces the local catalog with the server's, deleting the items,
     * cursors, and pending mutations of feeds no longer subscribed.
     */
    suspend fun replaceCatalog(catalog: RssCatalog): CatalogDiff

    /**
     * Writes one subscription. The watermark only advances, and a row that
     * arrives without its feed summary (a `/rss_update_subscription` reply)
     * does not erase the cached one.
     */
    suspend fun upsertSubscription(subscription: RssSubscription)

    suspend fun upsertFolder(folder: RssFolder)

    /** Ordered by display order, then name. */
    suspend fun folders(): List<RssFolder>

    suspend fun folder(id: String): RssFolder?

    /** Ordered by subscription id. */
    suspend fun subscriptions(): List<RssSubscription>

    suspend fun subscription(id: String): RssSubscription?

    /** The feed ids a scope covers, honouring folder nesting; sorted. */
    suspend fun feedIds(scope: RssItemScope): List<String>

    /**
     * Writes a page of items from the server. An item with a queued local
     * read or favorite change keeps its local flags (the local intent is
     * newer than whatever the server had); everything else takes the
     * server's copy.
     */
    suspend fun upsertItems(items: List<RssItem>)

    /** One page of items, read state computed and `subscriptionId` filled in. */
    suspend fun items(query: ItemQuery): List<RssItem>

    suspend fun item(
        feedId: String,
        sortKey: String,
    ): RssItem?

    /** Unread counts keyed by subscription id (absent = zero). */
    suspend fun unreadCounts(): Map<String, Int>

    /** Per-feed full-text search over cached items, newest first. */
    suspend fun search(
        feedId: String,
        query: String,
        limit: Int = 100,
    ): List<RssItem>

    suspend fun itemCount(feedId: String): Int

    /** Marks an item read or unread locally (an explicit mark) and queues the change. */
    suspend fun setRead(
        feedId: String,
        sortKey: String,
        isRead: Boolean,
    )

    /** Favorites or unfavorites an item locally and queues the change. */
    suspend fun setFavorite(
        feedId: String,
        sortKey: String,
        isFavorite: Boolean,
    )

    /**
     * Mark-all-read for one subscription, the way the server does it:
     * advance the watermark and flip items explicitly marked unread. A
     * null watermark means now.
     */
    suspend fun markAllRead(
        subscriptionId: String,
        watermark: String? = null,
    )

    /**
     * Applies state rows the server reported (the state sync) to the items
     * this device has, without queueing anything. A flag with a queued
     * local change is left alone; an item not cached here is skipped.
     */
    suspend fun applyServerStates(states: List<RssItemState>)

    /** Applies a watermark the server reported without queueing anything. */
    suspend fun applyServerWatermark(
        subscriptionId: String,
        watermark: String,
    )

    /** In insertion order. */
    suspend fun pendingMutations(): List<PendingMutation>

    suspend fun pendingCount(): Int

    /** Whether an item has a queued change (the UI's "queued" mark). */
    suspend fun hasPending(
        feedId: String,
        sortKey: String,
    ): Boolean

    suspend fun deletePending(ids: List<Long>)

    /** All defaults when the feed has never synced. */
    suspend fun syncState(feedId: String): FeedSyncState

    suspend fun setSyncState(
        feedId: String,
        state: FeedSyncState,
    )
}

/**
 * What [RssStore.replaceCatalog] removed, so the app can drop the
 * per-subscription web-view profile of departed subscriptions.
 */
data class CatalogDiff(
    val removedSubscriptionIds: List<String>,
    val removedDataStoreUuids: List<String>,
    val removedFeedIds: List<String>,
)

data class ItemQuery(
    val scope: RssItemScope,
    val filter: RssItemFilter = RssItemFilter.ALL,
    val ordering: RssOrderingMode = RssOrderingMode.NEWEST_FIRST,
    val limit: Int = 50,
    val offset: Int = 0,
)

/** What a queued mutation does. */
enum class PendingKind(
    val wire: String,
) {
    READ("read"),
    FAVORITE("favorite"),
    MARK_ALL_READ("mark_all_read"),
    ;

    companion object {
        fun fromWire(value: String): PendingKind? = entries.firstOrNull { it.wire == value }
    }
}

/** One queued mutation awaiting a push to the server. */
data class PendingMutation(
    val id: Long,
    val kind: PendingKind,
    val feedId: String,
    val sortKey: String,
    val subscriptionId: String,
    val value: Boolean,
)

/** Sync bookkeeping for one feed. */
data class FeedSyncState(
    /** The `fetched_key` to continue since-sync from; empty before the first sync. */
    val sinceCursor: String = "",
    /** The merged-listing cursor for "load older"; empty before the first page. */
    val olderCursor: String = "",
    val olderExhausted: Boolean = false,
    val lastSyncedAt: String = "",
    /** The state-sync cursor (opaque); empty before the first pull. */
    val stateCursor: String = "",
)

/**
 * The pure rules both stores share, so the in-memory store the tests run
 * against and the Room store the device runs cannot drift on the parts
 * that matter.
 */
object RssRules {
    /**
     * The read-state rule, the same one the server applies: an explicit
     * mark (local or server-reported) wins outright; otherwise the item is
     * read if the server said so or it was published at or before the
     * subscription's watermark. ISO timestamps compare as strings.
     */
    fun isRead(
        isRead: Boolean,
        stateIsExplicit: Boolean,
        publishedAt: String,
        watermark: String,
    ): Boolean = if (stateIsExplicit) isRead else isRead || publishedAt <= watermark

    /** The ISO date an item's day-grouping keys on. */
    fun dayKey(publishedAt: String): String = publishedAt.take(10)

    /**
     * The four orderings as a comparator over items (the server only ever
     * orders by sort key; the day-grouped modes are the client's).
     */
    fun comparator(ordering: RssOrderingMode): Comparator<RssItem> =
        when (ordering) {
            RssOrderingMode.NEWEST_FIRST -> compareByDescending { it.sortKey }
            RssOrderingMode.OLDEST_FIRST -> compareBy { it.sortKey }
            RssOrderingMode.NEWEST_DAY_OLDEST_WITHIN ->
                compareByDescending<RssItem> { dayKey(it.publishedAt) }.thenBy { it.sortKey }
            RssOrderingMode.OLDEST_DAY_NEWEST_WITHIN ->
                compareBy<RssItem> { dayKey(it.publishedAt) }.thenByDescending { it.sortKey }
        }

    /**
     * The search tokens of free text: lower-cased runs of letters and
     * digits, so operator words (`NOT`, `OR`) and syntax characters never
     * reach the FTS parser; empty when there is nothing searchable. Each
     * token is a prefix match, which is what a search-as-you-type field
     * needs and why the index has no stemmer.
     */
    fun searchTokens(text: String): List<String> =
        text
            .lowercase()
            .split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.isNotEmpty() }

    /** The FTS4 MATCH expression for [text], or null when there is nothing to search. */
    fun ftsQuery(text: String): String? {
        val tokens = searchTokens(text)
        if (tokens.isEmpty()) return null
        return tokens.joinToString(" ") { "$it*" }
    }

    /** The indexed text of an item body: tags stripped, whitespace collapsed. */
    fun bodyText(html: String): String = HtmlText.toPlainText(html).replace(Regex("\\s+"), " ").trim()

    /** Now, in the second-resolution ISO form the Apple store writes (`2026-09-13T20:15:30Z`). */
    fun isoNow(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
}
