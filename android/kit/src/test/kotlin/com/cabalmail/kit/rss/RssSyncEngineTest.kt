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
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * The sync engine against a scripted [RssClient] and the in-memory store,
 * mirroring the Apple kit's `RssSyncEngineTests`: initial population, the
 * since- and state-sync loops, load older, and the ordered drain.
 */
class RssSyncEngineTest {
    /**
     * Scripted responses per call family; an unscripted state sync answers
     * with an empty exhausted page (most tests do not care), an unscripted
     * item or list page throws.
     */
    private class FakeRssClient : RssClient {
        var catalog = RssCatalog()
        val listPages = ArrayDeque<RssItemsPage>()
        val syncPages = ArrayDeque<RssSyncPage>()
        val statePages = ArrayDeque<RssStateSyncPage>()
        val listCalls = mutableListOf<String?>()
        val syncCalls = mutableListOf<String>()
        val stateCalls = mutableListOf<String>()
        val stateBatches = mutableListOf<List<RssItemStateChange>>()
        val markAllReadScopes = mutableListOf<RssItemScope>()
        val pushLog = mutableListOf<String>()
        var pushFailure: Throwable? = null
        var markAllReadWatermark = "server-w"

        override suspend fun listSubscriptions() = catalog

        override suspend fun listItems(
            scope: RssItemScope,
            filter: RssItemFilter,
            order: RssItemOrder,
            limit: Int,
            cursor: String?,
        ): RssItemsPage {
            listCalls += cursor
            return listPages.removeFirstOrNull() ?: error("unscripted list page")
        }

        override suspend fun syncItems(
            subscriptionId: String,
            since: String,
            limit: Int,
        ): RssSyncPage {
            syncCalls += since
            return syncPages.removeFirstOrNull() ?: error("unscripted sync page")
        }

        override suspend fun syncItemStates(
            subscriptionId: String,
            since: String,
            limit: Int,
        ): RssStateSyncPage {
            stateCalls += since
            return statePages.removeFirstOrNull() ?: RssStateSyncPage()
        }

        override suspend fun setItemState(changes: List<RssItemStateChange>): Int {
            pushFailure?.let { throw it }
            pushLog += "state"
            stateBatches += changes
            return changes.size
        }

        override suspend fun markAllRead(scope: RssItemScope): RssMarkAllReadResult {
            pushFailure?.let { throw it }
            pushLog += "mark_all_read"
            markAllReadScopes += scope
            return RssMarkAllReadResult(readWatermark = markAllReadWatermark)
        }

        override suspend fun updateSubscription(
            subscriptionId: String,
            update: RssSubscriptionUpdate,
        ): RssSubscription = catalog.subscriptions.first { it.subscriptionId == subscriptionId }.applying(update)

        override suspend fun updateRssFolder(
            folderId: String,
            update: RssFolderUpdate,
        ): RssFolder = catalog.folders.first { it.folderId == folderId }.applying(update)

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

    private val s1 = RssSubscription(subscriptionId = "s1", feedId = "f1", readWatermark = "w", dataStoreUuid = "u1")
    private val s2 = RssSubscription(subscriptionId = "s2", feedId = "f2")

    private fun item(
        n: Int,
        feedId: String = "f1",
        isRead: Boolean = false,
    ) = RssItem(
        feedId = feedId,
        sortKey = "2026-01-${n.toString().padStart(2, '0')}T10:00:00+00:00#i$n",
        itemId = "i$n",
        publishedAt = "2026-01-${n.toString().padStart(2, '0')}T10:00:00+00:00",
        fetchedKey = "2026-02-${n.toString().padStart(2, '0')}T00:00:00+00:00#i$n",
        isRead = isRead,
    )

    private fun engine(
        client: FakeRssClient,
        store: RssStore = InMemoryRssStore(),
    ) = RssSyncEngine(client, store)

    @Test
    fun `initial population then incremental since-sync`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            client.listPages += RssItemsPage(items = listOf(item(5), item(4), item(3)), nextCursor = "older-1")
            client.syncPages += RssSyncPage(items = listOf(item(6)), nextSince = item(6).fetchedKey, hasMore = false)
            val engine = engine(client, store)

            assertEquals(4, engine.syncItems(s1))

            val state = store.syncState("f1")
            assertEquals(item(6).fetchedKey, state.sinceCursor)
            assertEquals("older-1", state.olderCursor)
            assertFalse(state.olderExhausted)
            assertEquals(
                listOf("i6", "i5", "i4", "i3"),
                store.items(ItemQuery(RssItemScope.Subscription("s1"))).map { it.itemId },
            )
            assertEquals(listOf(item(5).fetchedKey), client.syncCalls, "the first since call uses the max fetched key")

            client.syncPages += RssSyncPage(items = listOf(item(7)), nextSince = item(7).fetchedKey, hasMore = true)
            client.syncPages += RssSyncPage(items = listOf(item(8)), nextSince = item(8).fetchedKey, hasMore = false)
            assertEquals(2, engine.syncItems(s1))
            assertEquals(1, client.listCalls.size, "no second initial load")
            assertEquals(item(8).fetchedKey, store.syncState("f1").sinceCursor)
            assertEquals(3, client.syncCalls.size)
        }

    @Test
    fun `an empty feed gets the sentinel cursor, not another initial load`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            client.listPages += RssItemsPage(items = emptyList(), nextCursor = null)
            client.syncPages += RssSyncPage()
            client.syncPages += RssSyncPage()
            val engine = engine(client, store)

            assertEquals(0, engine.syncItems(s1))
            assertEquals(0, engine.syncItems(s1))

            assertEquals(1, client.listCalls.size)
            assertEquals(listOf("", ""), client.syncCalls)
            assertEquals(RssSyncEngine.SENTINEL_CURSOR, store.syncState("f1").sinceCursor)
            assertTrue(store.syncState("f1").olderExhausted)
        }

    @Test
    fun `load older follows the cursor until exhausted`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            store.setSyncState("f1", FeedSyncState(sinceCursor = "x", olderCursor = "c1"))
            client.listPages += RssItemsPage(items = listOf(item(1)), nextCursor = "c2")
            client.listPages += RssItemsPage(items = listOf(item(2)), nextCursor = null)
            val engine = engine(client, store)

            assertEquals(1, engine.loadOlder(s1))
            assertEquals(listOf("c1"), client.listCalls)
            assertEquals(1, engine.loadOlder(s1))
            assertTrue(store.syncState("f1").olderExhausted)
            assertEquals(0, engine.loadOlder(s1))
            assertEquals(2, client.listCalls.size, "no request once exhausted")
        }

    @Test
    fun `drain coalesces item marks, batches them, and clears the queue`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            store.upsertItems(listOf(item(1), item(2)))
            store.setRead("f1", item(1).sortKey, true)
            store.setFavorite("f1", item(1).sortKey, true)
            store.setRead("f1", item(2).sortKey, true)
            store.setRead("f1", item(2).sortKey, false)
            store.markAllRead("s1", watermark = "w")
            val engine = engine(client, store)

            assertEquals(4, engine.drainPending())

            assertEquals(0, store.pendingCount())
            val changes = client.stateBatches.single().sortedBy { it.sortKey }
            assertEquals(2, changes.size)
            assertEquals(true, changes[0].isRead)
            assertEquals(true, changes[0].isFavorite)
            assertEquals(false, changes[1].isRead)
            assertNull(changes[1].isFavorite)
            assertEquals(listOf<RssItemScope>(RssItemScope.Subscription("s1")), client.markAllReadScopes)
            assertEquals("w", store.subscription("s1")?.readWatermark, "MAX keeps the local watermark ahead")
        }

    @Test
    fun `drain replays a mark-all-read as a fence in queue order`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            store.upsertItems(listOf(item(1), item(2)))
            store.setRead("f1", item(1).sortKey, true)
            store.markAllRead("s1")
            store.setRead("f1", item(2).sortKey, false)
            store.setFavorite("f1", item(2).sortKey, true)
            val engine = engine(client, store)

            engine.drainPending()

            assertEquals(listOf("state", "mark_all_read", "state"), client.pushLog)
            assertEquals(listOf(item(1).sortKey), client.stateBatches[0].map { it.sortKey })
            val second = client.stateBatches[1].single()
            assertEquals(item(2).sortKey, second.sortKey)
            assertEquals(false, second.isRead)
            assertEquals(true, second.isFavorite)
            assertEquals(0, store.pendingCount())
        }

    @Test
    fun `state sync applies marks from other devices and keeps its cursor`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1.copy(readWatermark = "2026-01-03T23:59:59+00:00"))
            store.setSyncState("f1", FeedSyncState(sinceCursor = RssSyncEngine.SENTINEL_CURSOR))
            store.upsertItems((1..5).map { item(it) })
            client.syncPages += RssSyncPage()
            client.statePages +=
                RssStateSyncPage(
                    states = listOf(RssItemState("f1", item(2).sortKey, isRead = false, isReadExplicit = true)),
                    nextSince = "c1",
                    hasMore = true,
                )
            client.statePages +=
                RssStateSyncPage(
                    states =
                        listOf(
                            RssItemState("f1", item(5).sortKey, isFavorite = true),
                            RssItemState("f1", "not-cached", isRead = true),
                        ),
                    nextSince = "c2",
                    hasMore = false,
                )
            val engine = engine(client, store)

            engine.syncItems(s1)

            assertEquals(listOf("", "c1"), client.stateCalls)
            assertEquals("c2", store.syncState("f1").stateCursor)
            val listed = store.items(ItemQuery(RssItemScope.All, ordering = RssOrderingMode.OLDEST_FIRST))
            assertEquals(listOf(true, false, true, false, false), listed.map { it.isRead })
            assertEquals(listOf(false, true, false, false, false), listed.map { it.isReadExplicit })
            assertEquals(listOf(false, false, false, false, true), listed.map { it.isFavorite })
            assertEquals(5, store.itemCount("f1"))

            // A queued local read that failed to push wins over the next state page's read flag,
            // while the favorite flag (no queued change) still applies.
            client.pushFailure = IOException("offline")
            engine.setRead(listed[0], true)
            client.syncPages += RssSyncPage()
            client.statePages +=
                RssStateSyncPage(
                    states = listOf(RssItemState("f1", item(1).sortKey, isRead = false, isFavorite = true)),
                    nextSince = "c3",
                )
            engine.syncItems(s1)
            val first = store.item("f1", item(1).sortKey)!!
            assertTrue(first.isRead)
            assertTrue(first.isFavorite)
        }

    @Test
    fun `a failed push leaves the queue for the next drain`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            store.upsertSubscription(s1)
            store.upsertItems(listOf(item(1)))
            client.pushFailure = IOException("offline")
            val engine = engine(client, store)

            engine.setRead(item(1), true)

            assertTrue(store.item("f1", item(1).sortKey)!!.isRead)
            assertEquals(1, store.pendingCount())
            client.pushFailure = null
            assertEquals(1, engine.drainPending())
            assertEquals(0, store.pendingCount())
        }

    @Test
    fun `sync all reports per-feed failures and drops departed subscriptions`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            client.catalog = RssCatalog(subscriptions = listOf(s1, s2))
            client.listPages += RssItemsPage(items = listOf(item(1)), nextCursor = null)
            client.listPages += RssItemsPage(items = listOf(item(2, feedId = "f2")), nextCursor = null)
            client.syncPages += RssSyncPage()
            client.syncPages += RssSyncPage()
            val engine = engine(client, store).apply { concurrency = 1 }

            assertTrue(engine.syncAll().isEmpty())
            assertEquals(1, store.itemCount("f1"))
            assertEquals(1, store.itemCount("f2"))

            client.catalog = RssCatalog(subscriptions = listOf(s1))
            client.syncPages += RssSyncPage()
            assertTrue(engine.syncAll().isEmpty())
            assertEquals(0, store.itemCount("f2"))
            assertEquals(1, store.itemCount("f1"))

            // A feed whose page is unscripted fails on its own; the run still completes.
            client.catalog = RssCatalog(subscriptions = listOf(s1, s2))
            client.syncPages += RssSyncPage()
            val failures = engine.syncAll()
            assertEquals(setOf("s2"), failures.keys)
        }

    @Test
    fun `optimistic subscription and folder updates land in the store before and after the round trip`() =
        runTest {
            val client = FakeRssClient()
            val store = InMemoryRssStore()
            val folder = RssFolder("d1", name = "News")
            client.catalog = RssCatalog(folders = listOf(folder), subscriptions = listOf(s1))
            store.replaceCatalog(client.catalog)
            val engine = engine(client, store)

            val update = RssSubscriptionUpdate(defaultRemoteContent = RssRemoteContentMode.SHOW)
            val updated = engine.updateSubscription(s1, update)
            assertEquals(RssRemoteContentMode.SHOW, updated.defaultRemoteContent)
            assertEquals(RssRemoteContentMode.SHOW, store.subscription("s1")?.defaultRemoteContent)
            assertEquals(s1, engine.updateSubscription(s1, RssSubscriptionUpdate()), "an empty update makes no request")

            val movedFolder = engine.updateFolder(folder, RssFolderUpdate(defaultFilter = RssItemFilter.ALL))
            assertEquals(RssItemFilter.ALL, movedFolder.defaultFilter)
            assertEquals(RssItemFilter.ALL, store.folder("d1")?.defaultFilter)
        }
}
