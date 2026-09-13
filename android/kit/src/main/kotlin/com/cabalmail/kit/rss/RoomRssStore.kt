package com.cabalmail.kit.rss

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.FtsOptions
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RawQuery
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import androidx.room.withTransaction
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteQuery
import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssWire
import com.cabalmail.kit.settings.wireEnum

/**
 * Room-backed [RssStore]. Unlike the envelope cache, items are exploded
 * into columns: search needs real text columns, and the list, the filters
 * and the unread counts are SQL over them. The schema and the SQL mirror
 * the Apple store's (`RssStore.swift`, schema version 4), which the kit's
 * contract tests verified on real SQLite; here the DAO is exercised
 * on-device and the contract by [InMemoryRssStore]'s tests.
 *
 * Full-text search is Room's `@Fts4` content table over `title` and
 * `body_text` with the `unicode61` tokenizer and no stemmer (a stemmer
 * rewrites stored tokens in ways a typed prefix no longer matches). FTS4
 * has no built-in rank, so results are newest first — for per-feed search
 * over a few hundred items that is what users expect anyway.
 */
@Entity(tableName = "rss_folders")
data class RssFolderRow(
    @PrimaryKey @ColumnInfo(name = "folder_id") val folderId: String,
    @ColumnInfo(name = "parent_folder_id") val parentFolderId: String,
    val name: String,
    @ColumnInfo(name = "display_order") val displayOrder: Int,
    @ColumnInfo(name = "default_filter") val defaultFilter: String,
)

@Entity(tableName = "rss_subscriptions", indices = [Index("feed_id")])
data class RssSubscriptionRow(
    @PrimaryKey @ColumnInfo(name = "subscription_id") val subscriptionId: String,
    @ColumnInfo(name = "feed_id") val feedId: String,
    @ColumnInfo(name = "folder_id") val folderId: String,
    @ColumnInfo(name = "custom_title") val customTitle: String,
    @ColumnInfo(name = "ordering_mode") val orderingMode: String,
    @ColumnInfo(name = "default_open_mode") val defaultOpenMode: String,
    @ColumnInfo(name = "default_styling") val defaultStyling: String,
    @ColumnInfo(name = "default_remote_content") val defaultRemoteContent: String,
    @ColumnInfo(name = "default_filter") val defaultFilter: String,
    @ColumnInfo(name = "notifications_enabled") val notificationsEnabled: Boolean,
    @ColumnInfo(name = "credentials_scheme") val credentialsScheme: String,
    @ColumnInfo(name = "read_watermark") val readWatermark: String,
    @ColumnInfo(name = "data_store_uuid") val dataStoreUuid: String,
    @ColumnInfo(name = "created_at") val createdAt: String,
    /** The feed summary as wire JSON; empty when the row arrived without one. */
    @ColumnInfo(name = "feed_json") val feedJson: String,
)

@Entity(
    tableName = "rss_items",
    indices = [
        Index(value = ["feed_id", "sort_key"], unique = true),
        Index(value = ["feed_id", "fetched_key"]),
        Index(value = ["feed_id", "published_at"]),
    ],
)
data class RssItemRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(name = "feed_id") val feedId: String,
    @ColumnInfo(name = "sort_key") val sortKey: String,
    @ColumnInfo(name = "item_id") val itemId: String,
    val guid: String,
    val title: String,
    val author: String,
    val url: String,
    @ColumnInfo(name = "published_at") val publishedAt: String,
    @ColumnInfo(name = "updated_at") val updatedAt: String,
    @ColumnInfo(name = "fetched_at") val fetchedAt: String,
    @ColumnInfo(name = "fetched_key") val fetchedKey: String,
    @ColumnInfo(name = "summary_html") val summaryHtml: String,
    @ColumnInfo(name = "content_html") val contentHtml: String,
    @ColumnInfo(name = "body_text") val bodyText: String,
    @ColumnInfo(name = "is_read") val isRead: Boolean,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean,
    @ColumnInfo(name = "state_is_explicit") val stateIsExplicit: Boolean,
    @ColumnInfo(name = "cached_at") val cachedAt: String,
)

/** The search index over [RssItemRow]; Room keeps it current with triggers. */
@Fts4(contentEntity = RssItemRow::class, tokenizer = FtsOptions.TOKENIZER_UNICODE61)
@Entity(tableName = "rss_items_fts")
data class RssItemFtsRow(
    val title: String,
    @ColumnInfo(name = "body_text") val bodyText: String,
)

@Entity(tableName = "rss_feed_sync")
data class RssFeedSyncRow(
    @PrimaryKey @ColumnInfo(name = "feed_id") val feedId: String,
    @ColumnInfo(name = "since_cursor") val sinceCursor: String,
    @ColumnInfo(name = "older_cursor") val olderCursor: String,
    @ColumnInfo(name = "older_exhausted") val olderExhausted: Boolean,
    @ColumnInfo(name = "last_synced_at") val lastSyncedAt: String,
    @ColumnInfo(name = "state_cursor") val stateCursor: String,
)

@Entity(tableName = "rss_pending")
data class RssPendingRow(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val kind: String,
    @ColumnInfo(name = "feed_id") val feedId: String,
    @ColumnInfo(name = "sort_key") val sortKey: String,
    @ColumnInfo(name = "subscription_id") val subscriptionId: String,
    val value: Boolean,
    @ColumnInfo(name = "created_at") val createdAt: String,
)

/** One listed item: the row's columns plus the computed read state and its subscription. */
data class RssItemView(
    @ColumnInfo(name = "feed_id") val feedId: String,
    @ColumnInfo(name = "sort_key") val sortKey: String,
    @ColumnInfo(name = "item_id") val itemId: String,
    val guid: String,
    val title: String,
    val author: String,
    val url: String,
    @ColumnInfo(name = "published_at") val publishedAt: String,
    @ColumnInfo(name = "updated_at") val updatedAt: String,
    @ColumnInfo(name = "fetched_at") val fetchedAt: String,
    @ColumnInfo(name = "fetched_key") val fetchedKey: String,
    @ColumnInfo(name = "summary_html") val summaryHtml: String,
    @ColumnInfo(name = "content_html") val contentHtml: String,
    @ColumnInfo(name = "effective_read") val effectiveRead: Boolean,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean,
    @ColumnInfo(name = "state_is_explicit") val stateIsExplicit: Boolean,
    @ColumnInfo(name = "subscription_id") val subscriptionId: String,
)

data class RssUnreadCountRow(
    @ColumnInfo(name = "subscription_id") val subscriptionId: String,
    val count: Int,
)

@Dao
interface RssDao {
    // folders
    @Upsert
    suspend fun upsertFolder(row: RssFolderRow)

    @Query("SELECT * FROM rss_folders ORDER BY display_order, name")
    suspend fun folders(): List<RssFolderRow>

    @Query("DELETE FROM rss_folders WHERE folder_id NOT IN (:keep)")
    suspend fun deleteFoldersNotIn(keep: List<String>)

    @Query("DELETE FROM rss_folders")
    suspend fun deleteAllFolders()

    // subscriptions
    @Upsert
    suspend fun upsertSubscription(row: RssSubscriptionRow)

    @Query("SELECT * FROM rss_subscriptions WHERE subscription_id = :id")
    suspend fun subscription(id: String): RssSubscriptionRow?

    @Query("SELECT * FROM rss_subscriptions ORDER BY subscription_id")
    suspend fun subscriptions(): List<RssSubscriptionRow>

    @Query("DELETE FROM rss_subscriptions WHERE subscription_id = :id")
    suspend fun deleteSubscription(id: String)

    @Query("DELETE FROM rss_subscriptions")
    suspend fun deleteAllSubscriptions()

    @Query("UPDATE rss_subscriptions SET read_watermark = MAX(read_watermark, :watermark) WHERE subscription_id = :id")
    suspend fun advanceWatermark(
        id: String,
        watermark: String,
    )

    // items
    @Upsert
    suspend fun upsertItem(row: RssItemRow)

    @Query("SELECT * FROM rss_items WHERE feed_id = :feedId AND sort_key = :sortKey")
    suspend fun itemRow(
        feedId: String,
        sortKey: String,
    ): RssItemRow?

    @RawQuery
    suspend fun itemViews(query: SupportSQLiteQuery): List<RssItemView>

    @Query(
        "SELECT s.subscription_id AS subscription_id, COUNT(*) AS count FROM rss_items i " +
            "JOIN rss_subscriptions s ON s.feed_id = i.feed_id " +
            "WHERE NOT ($READ_EXPRESSION) GROUP BY s.subscription_id",
    )
    suspend fun unreadCounts(): List<RssUnreadCountRow>

    @Query("SELECT COUNT(*) FROM rss_items WHERE feed_id = :feedId")
    suspend fun itemCount(feedId: String): Int

    @Query(
        "UPDATE rss_items SET is_read = :isRead, state_is_explicit = 1 " +
            "WHERE feed_id = :feedId AND sort_key = :sortKey",
    )
    suspend fun setRead(
        feedId: String,
        sortKey: String,
        isRead: Boolean,
    )

    @Query("UPDATE rss_items SET is_favorite = :isFavorite WHERE feed_id = :feedId AND sort_key = :sortKey")
    suspend fun setFavorite(
        feedId: String,
        sortKey: String,
        isFavorite: Boolean,
    )

    @Query(
        "UPDATE rss_items SET is_read = :isRead, state_is_explicit = :isExplicit " +
            "WHERE feed_id = :feedId AND sort_key = :sortKey",
    )
    suspend fun applyReadState(
        feedId: String,
        sortKey: String,
        isRead: Boolean,
        isExplicit: Boolean,
    )

    @Query(
        "UPDATE rss_items SET is_read = 1 WHERE feed_id = :feedId AND state_is_explicit = 1 AND is_read = 0 " +
            "AND published_at <= :watermark",
    )
    suspend fun flipExplicitUnread(
        feedId: String,
        watermark: String,
    )

    @Query("DELETE FROM rss_items WHERE feed_id = :feedId")
    suspend fun deleteItems(feedId: String)

    @Query("DELETE FROM rss_items")
    suspend fun deleteAllItems()

    // pending
    @Upsert
    suspend fun insertPending(row: RssPendingRow): Long

    @Query("SELECT * FROM rss_pending ORDER BY id")
    suspend fun pending(): List<RssPendingRow>

    @Query("SELECT COUNT(*) FROM rss_pending")
    suspend fun pendingCount(): Int

    @Query("SELECT COUNT(*) FROM rss_pending WHERE kind = :kind AND feed_id = :feedId AND sort_key = :sortKey")
    suspend fun pendingCount(
        kind: String,
        feedId: String,
        sortKey: String,
    ): Int

    @Query("SELECT COUNT(*) FROM rss_pending WHERE feed_id = :feedId AND sort_key = :sortKey")
    suspend fun pendingCountForItem(
        feedId: String,
        sortKey: String,
    ): Int

    @Query("SELECT feed_id || '#' || sort_key FROM rss_pending WHERE kind IN ('read', 'favorite')")
    suspend fun shieldedItemKeys(): List<String>

    @Query("DELETE FROM rss_pending WHERE kind = :kind AND feed_id = :feedId AND sort_key = :sortKey")
    suspend fun deletePendingOfKind(
        kind: String,
        feedId: String,
        sortKey: String,
    )

    @Query("DELETE FROM rss_pending WHERE id IN (:ids)")
    suspend fun deletePending(ids: List<Long>)

    @Query("DELETE FROM rss_pending WHERE feed_id = :feedId")
    suspend fun deletePendingForFeed(feedId: String)

    @Query("DELETE FROM rss_pending")
    suspend fun deleteAllPending()

    // sync cursors
    @Upsert
    suspend fun upsertSyncState(row: RssFeedSyncRow)

    @Query("SELECT * FROM rss_feed_sync WHERE feed_id = :feedId")
    suspend fun syncState(feedId: String): RssFeedSyncRow?

    @Query("DELETE FROM rss_feed_sync WHERE feed_id = :feedId")
    suspend fun deleteSyncState(feedId: String)

    @Query("DELETE FROM rss_feed_sync")
    suspend fun deleteAllSyncStates()

    companion object {
        /**
         * The read-state rule in SQL ([RssRules.isRead]); `i` is the items
         * alias and the subscription's watermark is looked up per row.
         */
        const val READ_EXPRESSION =
            "CASE WHEN i.state_is_explicit = 1 THEN i.is_read " +
                "ELSE (i.is_read = 1 OR i.published_at <= COALESCE(" +
                "(SELECT s.read_watermark FROM rss_subscriptions s WHERE s.feed_id = i.feed_id LIMIT 1), '')) END"

        const val ITEM_COLUMNS =
            "i.feed_id, i.sort_key, i.item_id, i.guid, i.title, i.author, i.url, i.published_at, " +
                "i.updated_at, i.fetched_at, i.fetched_key, i.summary_html, i.content_html, " +
                "($READ_EXPRESSION) AS effective_read, i.is_favorite, i.state_is_explicit, " +
                "COALESCE((SELECT s.subscription_id FROM rss_subscriptions s " +
                "WHERE s.feed_id = i.feed_id LIMIT 1), '') AS subscription_id"
    }
}

@Database(
    entities = [
        RssFolderRow::class,
        RssSubscriptionRow::class,
        RssItemRow::class,
        RssItemFtsRow::class,
        RssFeedSyncRow::class,
        RssPendingRow::class,
    ],
    version = 1,
    exportSchema = false,
)
abstract class RssDatabase : RoomDatabase() {
    abstract fun dao(): RssDao

    companion object {
        fun open(context: Context): RssDatabase =
            Room
                .databaseBuilder(context, RssDatabase::class.java, "rss_cache.db")
                // A cache rebuilds itself from the server; never block an upgrade on it.
                .fallbackToDestructiveMigration(dropAllTables = true)
                .build()
    }
}

class RoomRssStore(
    private val database: RssDatabase,
    private val clock: () -> String = RssRules::isoNow,
) : RssStore {
    private val dao = database.dao()

    companion object {
        /** Opens the on-disk store; consumers see only the [RssStore] interface. */
        fun open(context: Context): RssStore = RoomRssStore(RssDatabase.open(context))

        private fun orderClause(ordering: RssOrderingMode): String =
            when (ordering) {
                RssOrderingMode.NEWEST_FIRST -> "i.sort_key DESC"
                RssOrderingMode.OLDEST_FIRST -> "i.sort_key ASC"
                RssOrderingMode.NEWEST_DAY_OLDEST_WITHIN -> "substr(i.published_at, 1, 10) DESC, i.sort_key ASC"
                RssOrderingMode.OLDEST_DAY_NEWEST_WITHIN -> "substr(i.published_at, 1, 10) ASC, i.sort_key DESC"
            }
    }

    override suspend fun clear() =
        database.withTransaction {
            dao.deleteAllPending()
            dao.deleteAllSyncStates()
            dao.deleteAllItems()
            dao.deleteAllSubscriptions()
            dao.deleteAllFolders()
        }

    // ------------------------------------------------------------- catalog

    override suspend fun replaceCatalog(catalog: RssCatalog): CatalogDiff =
        database.withTransaction {
            val existing = dao.subscriptions()
            val keep = catalog.subscriptions.map { it.subscriptionId }.toSet()
            val removed = existing.filter { it.subscriptionId !in keep }
            val keptFeeds = catalog.subscriptions.map { it.feedId }.toSet()
            val removedFeeds = removed.map { it.feedId }.toSet() - keptFeeds
            removed.forEach { dao.deleteSubscription(it.subscriptionId) }
            removedFeeds.forEach { deleteFeedRows(it) }
            catalog.subscriptions.forEach { upsertSubscriptionInTransaction(it) }
            val folderIds = catalog.folders.map { it.folderId }
            if (folderIds.isEmpty()) dao.deleteAllFolders() else dao.deleteFoldersNotIn(folderIds)
            catalog.folders.forEach { dao.upsertFolder(it.toRow()) }
            CatalogDiff(
                removedSubscriptionIds = removed.map { it.subscriptionId },
                removedDataStoreUuids = removed.map { it.dataStoreUuid }.filter { it.isNotEmpty() },
                removedFeedIds = removedFeeds.sorted(),
            )
        }

    override suspend fun upsertSubscription(subscription: RssSubscription) =
        database.withTransaction { upsertSubscriptionInTransaction(subscription) }

    private suspend fun upsertSubscriptionInTransaction(subscription: RssSubscription) {
        val existing = dao.subscription(subscription.subscriptionId)
        val incoming = subscription.toRow()
        dao.upsertSubscription(
            if (existing == null) {
                incoming
            } else {
                incoming.copy(
                    readWatermark = maxOf(existing.readWatermark, incoming.readWatermark),
                    feedJson = incoming.feedJson.ifEmpty { existing.feedJson },
                )
            },
        )
    }

    override suspend fun upsertFolder(folder: RssFolder) = dao.upsertFolder(folder.toRow())

    override suspend fun folders(): List<RssFolder> = dao.folders().map { it.toFolder() }

    override suspend fun folder(id: String): RssFolder? = folders().firstOrNull { it.folderId == id }

    override suspend fun subscriptions(): List<RssSubscription> = dao.subscriptions().map { it.toSubscription() }

    override suspend fun subscription(id: String): RssSubscription? = dao.subscription(id)?.toSubscription()

    override suspend fun feedIds(scope: RssItemScope): List<String> {
        val subs = dao.subscriptions()
        return when (scope) {
            RssItemScope.All -> subs.map { it.feedId }.toSet().sorted()
            is RssItemScope.Subscription ->
                listOfNotNull(subs.firstOrNull { it.subscriptionId == scope.subscriptionId }?.feedId)
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

    private suspend fun descendantFolderIds(folderId: String): Set<String> {
        val byParent = dao.folders().groupBy { it.parentFolderId }
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

    private suspend fun deleteFeedRows(feedId: String) {
        dao.deleteItems(feedId)
        dao.deleteSyncState(feedId)
        dao.deletePendingForFeed(feedId)
    }

    // --------------------------------------------------------------- items

    override suspend fun upsertItems(items: List<RssItem>) {
        if (items.isEmpty()) return
        database.withTransaction {
            val now = clock()
            val shielded = dao.shieldedItemKeys().toSet()
            for (item in items) {
                val existing = dao.itemRow(item.feedId, item.sortKey)
                val keepLocalState = existing != null && item.id in shielded
                dao.upsertItem(
                    RssItemRow(
                        id = existing?.id ?: 0,
                        feedId = item.feedId,
                        sortKey = item.sortKey,
                        itemId = item.itemId,
                        guid = item.guid,
                        title = item.title,
                        author = item.author,
                        url = item.url,
                        publishedAt = item.publishedAt,
                        updatedAt = item.updatedAt,
                        fetchedAt = item.fetchedAt,
                        fetchedKey = item.fetchedKey,
                        summaryHtml = item.summaryHtml,
                        contentHtml = item.contentHtml,
                        bodyText = RssRules.bodyText(item.bodyHtml),
                        isRead = if (keepLocalState) existing.isRead else item.isRead,
                        isFavorite = if (keepLocalState) existing.isFavorite else item.isFavorite,
                        stateIsExplicit = if (keepLocalState) existing.stateIsExplicit else item.isReadExplicit,
                        cachedAt = now,
                    ),
                )
            }
        }
    }

    override suspend fun items(query: ItemQuery): List<RssItem> {
        val feedIds = feedIds(query.scope)
        if (feedIds.isEmpty()) return emptyList()
        val clauses = mutableListOf("i.feed_id IN (${feedIds.joinToString(", ") { "?" }})")
        val binds = mutableListOf<Any>()
        binds.addAll(feedIds)
        when (query.filter) {
            RssItemFilter.ALL -> Unit
            RssItemFilter.UNREAD -> clauses += "NOT (${RssDao.READ_EXPRESSION})"
            RssItemFilter.FAVORITE -> clauses += "i.is_favorite = 1"
        }
        binds.add(query.limit)
        binds.add(query.offset)
        val sql =
            "SELECT ${RssDao.ITEM_COLUMNS} FROM rss_items i WHERE ${clauses.joinToString(" AND ")} " +
                "ORDER BY ${orderClause(query.ordering)} LIMIT ? OFFSET ?"
        return dao.itemViews(SimpleSQLiteQuery(sql, binds.toTypedArray())).map { it.toItem() }
    }

    override suspend fun item(
        feedId: String,
        sortKey: String,
    ): RssItem? =
        dao
            .itemViews(
                SimpleSQLiteQuery(
                    "SELECT ${RssDao.ITEM_COLUMNS} FROM rss_items i WHERE i.feed_id = ? AND i.sort_key = ?",
                    arrayOf(feedId, sortKey),
                ),
            ).firstOrNull()
            ?.toItem()

    override suspend fun unreadCounts(): Map<String, Int> =
        dao.unreadCounts().associate { it.subscriptionId to it.count }

    override suspend fun search(
        feedId: String,
        query: String,
        limit: Int,
    ): List<RssItem> {
        val match = RssRules.ftsQuery(query) ?: return emptyList()
        return dao
            .itemViews(
                SimpleSQLiteQuery(
                    "SELECT ${RssDao.ITEM_COLUMNS} FROM rss_items i JOIN rss_items_fts f ON f.rowid = i.id " +
                        "WHERE rss_items_fts MATCH ? AND i.feed_id = ? ORDER BY i.published_at DESC LIMIT ?",
                    arrayOf<Any>(match, feedId, limit),
                ),
            ).map { it.toItem() }
    }

    override suspend fun itemCount(feedId: String): Int = dao.itemCount(feedId)

    // --------------------------------------------------------- local state

    override suspend fun setRead(
        feedId: String,
        sortKey: String,
        isRead: Boolean,
    ) = database.withTransaction {
        dao.setRead(feedId, sortKey, isRead)
        enqueue(PendingKind.READ, feedId, sortKey, isRead)
    }

    override suspend fun setFavorite(
        feedId: String,
        sortKey: String,
        isFavorite: Boolean,
    ) = database.withTransaction {
        dao.setFavorite(feedId, sortKey, isFavorite)
        enqueue(PendingKind.FAVORITE, feedId, sortKey, isFavorite)
    }

    override suspend fun markAllRead(
        subscriptionId: String,
        watermark: String?,
    ) = database.withTransaction {
        val mark = watermark ?: clock()
        val sub = dao.subscription(subscriptionId) ?: return@withTransaction
        dao.advanceWatermark(subscriptionId, mark)
        dao.flipExplicitUnread(sub.feedId, mark)
        dao.insertPending(
            RssPendingRow(
                kind = PendingKind.MARK_ALL_READ.wire,
                feedId = sub.feedId,
                sortKey = "",
                subscriptionId = subscriptionId,
                value = false,
                createdAt = clock(),
            ),
        )
        Unit
    }

    override suspend fun applyServerStates(states: List<RssItemState>) {
        if (states.isEmpty()) return
        database.withTransaction {
            for (state in states) {
                if (dao.itemRow(state.feedId, state.sortKey) == null) continue
                if (dao.pendingCount(PendingKind.READ.wire, state.feedId, state.sortKey) == 0) {
                    dao.applyReadState(state.feedId, state.sortKey, state.isRead, state.isReadExplicit)
                }
                if (dao.pendingCount(PendingKind.FAVORITE.wire, state.feedId, state.sortKey) == 0) {
                    dao.setFavorite(state.feedId, state.sortKey, state.isFavorite)
                }
            }
        }
    }

    override suspend fun applyServerWatermark(
        subscriptionId: String,
        watermark: String,
    ) = dao.advanceWatermark(subscriptionId, watermark)

    override suspend fun pendingMutations(): List<PendingMutation> =
        dao.pending().mapNotNull { row ->
            PendingKind.fromWire(row.kind)?.let {
                PendingMutation(row.id, it, row.feedId, row.sortKey, row.subscriptionId, row.value)
            }
        }

    override suspend fun pendingCount(): Int = dao.pendingCount()

    override suspend fun hasPending(
        feedId: String,
        sortKey: String,
    ): Boolean = dao.pendingCountForItem(feedId, sortKey) > 0

    override suspend fun deletePending(ids: List<Long>) {
        if (ids.isNotEmpty()) dao.deletePending(ids)
    }

    private suspend fun enqueue(
        kind: PendingKind,
        feedId: String,
        sortKey: String,
        value: Boolean,
    ) {
        // The latest intent for an item wins; drop earlier queued flips of
        // the same kind so a drain never replays a superseded state.
        dao.deletePendingOfKind(kind.wire, feedId, sortKey)
        dao.insertPending(
            RssPendingRow(
                kind = kind.wire,
                feedId = feedId,
                sortKey = sortKey,
                subscriptionId = "",
                value = value,
                createdAt = clock(),
            ),
        )
    }

    // -------------------------------------------------------- sync cursors

    override suspend fun syncState(feedId: String): FeedSyncState =
        dao.syncState(feedId)?.let {
            FeedSyncState(it.sinceCursor, it.olderCursor, it.olderExhausted, it.lastSyncedAt, it.stateCursor)
        } ?: FeedSyncState()

    override suspend fun setSyncState(
        feedId: String,
        state: FeedSyncState,
    ) = dao.upsertSyncState(
        RssFeedSyncRow(
            feedId = feedId,
            sinceCursor = state.sinceCursor,
            olderCursor = state.olderCursor,
            olderExhausted = state.olderExhausted,
            lastSyncedAt = state.lastSyncedAt,
            stateCursor = state.stateCursor,
        ),
    )

    // ------------------------------------------------------------ mapping

    private fun RssFolder.toRow() = RssFolderRow(folderId, parentFolderId, name, displayOrder, defaultFilter.wire)

    private fun RssFolderRow.toFolder() =
        RssFolder(
            folderId = folderId,
            parentFolderId = parentFolderId,
            name = name,
            displayOrder = displayOrder,
            defaultFilter = wireEnum<RssItemFilter>(defaultFilter) ?: RssItemFilter.DEFAULT_FOR_FEEDS,
        )

    private fun RssSubscription.toRow() =
        RssSubscriptionRow(
            subscriptionId = subscriptionId,
            feedId = feedId,
            folderId = folderId,
            customTitle = customTitle,
            orderingMode = orderingMode.wire,
            defaultOpenMode = defaultOpenMode.wire,
            defaultStyling = defaultStyling.wire,
            defaultRemoteContent = defaultRemoteContent.wire,
            defaultFilter = defaultFilter.wire,
            notificationsEnabled = notificationsEnabled,
            credentialsScheme = credentialsScheme,
            readWatermark = readWatermark,
            dataStoreUuid = dataStoreUuid,
            createdAt = createdAt,
            feedJson = feed?.let { RssWire.json.encodeToString(RssFeedSummary.serializer(), it) }.orEmpty(),
        )

    private fun RssSubscriptionRow.toSubscription() =
        RssSubscription(
            subscriptionId = subscriptionId,
            feedId = feedId,
            folderId = folderId,
            customTitle = customTitle,
            orderingMode = wireEnum<RssOrderingMode>(orderingMode) ?: RssOrderingMode.NEWEST_FIRST,
            defaultOpenMode = wireEnum<RssOpenMode>(defaultOpenMode) ?: RssOpenMode.SUMMARY,
            defaultStyling = wireEnum<RssStyling>(defaultStyling) ?: RssStyling.READER,
            defaultRemoteContent = wireEnum<RssRemoteContentMode>(defaultRemoteContent) ?: RssRemoteContentMode.INHERIT,
            defaultFilter = wireEnum<RssItemFilter>(defaultFilter) ?: RssItemFilter.DEFAULT_FOR_FEEDS,
            notificationsEnabled = notificationsEnabled,
            credentialsScheme = credentialsScheme,
            readWatermark = readWatermark,
            dataStoreUuid = dataStoreUuid,
            createdAt = createdAt,
            feed =
                feedJson.ifEmpty { null }?.let {
                    runCatching { RssWire.json.decodeFromString(RssFeedSummary.serializer(), it) }.getOrNull()
                },
        )

    private fun RssItemView.toItem() =
        RssItem(
            feedId = feedId,
            sortKey = sortKey,
            subscriptionId = subscriptionId,
            itemId = itemId,
            guid = guid,
            title = title,
            author = author,
            url = url,
            publishedAt = publishedAt,
            updatedAt = updatedAt,
            fetchedAt = fetchedAt,
            fetchedKey = fetchedKey,
            summaryHtml = summaryHtml,
            contentHtml = contentHtml,
            isRead = effectiveRead,
            isReadExplicit = stateIsExplicit,
            isFavorite = isFavorite,
        )
}
