package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderDeleteResult
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemOrder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssItemsPage
import com.cabalmail.kit.models.RssMarkAllReadResult
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOpmlExport
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult
import com.cabalmail.kit.rss.InMemoryRssStore
import com.cabalmail.kit.rss.RssClient
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.MarkAsRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * The list and reader view models against the kit's in-memory store and a
 * recording client: the first render honours the store row's defaults
 * (the guard the plan asks for), a pill tap writes back once, the reader's
 * toggles write one field each, and a failed write leaves the reader's
 * state alone.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedViewModelsTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** Records writes; answers syncs with empty pages so the engine's loops end at once. */
    private class RecordingClient(
        private val rows: suspend (String) -> RssSubscription?,
    ) : RssClient {
        val subscriptionUpdates = mutableListOf<Pair<String, RssSubscriptionUpdate>>()
        val folderUpdates = mutableListOf<Pair<String, RssFolderUpdate>>()
        var failWrites: Throwable? = null

        override suspend fun listSubscriptions() = RssCatalog()

        override suspend fun listItems(
            scope: RssItemScope,
            filter: RssItemFilter,
            order: RssItemOrder,
            limit: Int,
            cursor: String?,
        ) = RssItemsPage()

        override suspend fun syncItems(
            subscriptionId: String,
            since: String,
            limit: Int,
        ) = RssSyncPage()

        override suspend fun syncItemStates(
            subscriptionId: String,
            since: String,
            limit: Int,
        ) = RssStateSyncPage()

        override suspend fun setItemState(changes: List<RssItemStateChange>): Int {
            failWrites?.let { throw it }
            return changes.size
        }

        override suspend fun markAllRead(scope: RssItemScope) = RssMarkAllReadResult(readWatermark = "w")

        override suspend fun updateSubscription(
            subscriptionId: String,
            update: RssSubscriptionUpdate,
        ): RssSubscription {
            failWrites?.let { throw it }
            subscriptionUpdates += subscriptionId to update
            // The server answers with the stored row after the change.
            return (rows(subscriptionId) ?: RssSubscription(subscriptionId, "f1")).applying(update)
        }

        override suspend fun updateRssFolder(
            folderId: String,
            update: RssFolderUpdate,
        ): RssFolder {
            folderUpdates += folderId to update
            return RssFolder(folderId, name = "News").applying(update)
        }

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

    private val store = InMemoryRssStore()
    private val client = RecordingClient { store.subscription(it) }
    private val engine = RssSyncEngine(client, store)
    private val events = FeedEventBus()
    private val preferences = MutableStateFlow(AppPreferences())
    private val preferenceWrites = mutableListOf<AppPreferences>()

    private val subscription =
        RssSubscription(
            subscriptionId = "s1",
            feedId = "f1",
            defaultFilter = RssItemFilter.FAVORITE,
            orderingMode = RssOrderingMode.OLDEST_FIRST,
            defaultOpenMode = RssOpenMode.ARTICLE,
            defaultStyling = RssStyling.NATIVE,
            defaultRemoteContent = RssRemoteContentMode.SHOW,
        )

    private fun item(
        n: Int,
        isFavorite: Boolean = false,
        url: String = "https://example.com/$n",
    ) = RssItem(
        feedId = "f1",
        sortKey = "2026-01-0${n}T10:00:00+00:00#i$n",
        itemId = "i$n",
        title = "Item $n",
        url = url,
        publishedAt = "2026-01-0${n}T10:00:00+00:00",
        fetchedKey = "2026-02-0${n}T00:00:00+00:00#i$n",
        summaryHtml = "<p>$n</p>",
        isFavorite = isFavorite,
    )

    private fun listModel(scope: RssItemScope) =
        FeedItemListViewModel(
            scope = scope,
            store = store,
            engine = { engine },
            events = events,
            preferences = preferences,
            updatePreferences = { transform ->
                preferences.value = transform(preferences.value)
                preferenceWrites += preferences.value
            },
        )

    private fun detailModel(item: RssItem) =
        FeedItemDetailViewModel(
            feedId = item.feedId,
            sortKey = item.sortKey,
            store = store,
            engine = { engine },
            events = events,
            preferences = preferences,
        )

    @Test
    fun `the feed list opens on the row's stored pill and ordering, and a tap writes the pill back once`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription)
            store.upsertItems(listOf(item(1), item(2, isFavorite = true)))

            val model = listModel(RssItemScope.Subscription("s1"))
            advanceUntilIdle()

            assertEquals(RssItemFilter.FAVORITE, model.state.value.filter)
            assertEquals(RssOrderingMode.OLDEST_FIRST, model.state.value.ordering)
            assertEquals(
                listOf("i2"),
                model.state.value.items
                    .map { it.itemId },
            )

            model.setFilter(RssItemFilter.ALL)
            advanceUntilIdle()
            assertEquals(
                listOf("i1", "i2"),
                model.state.value.items
                    .map { it.itemId },
            )
            assertEquals(
                listOf("s1" to RssSubscriptionUpdate(defaultFilter = RssItemFilter.ALL)),
                client.subscriptionUpdates,
            )
            assertEquals(
                RssItemFilter.ALL,
                model.state.value.subscription
                    ?.defaultFilter,
            )

            model.setFilter(RssItemFilter.ALL)
            advanceUntilIdle()
            assertEquals(1, client.subscriptionUpdates.size, "re-selecting the active pill writes nothing")
            assertTrue(preferenceWrites.isEmpty())
        }

    @Test
    fun `the list epoch advances with the open and each fresh start, never with a re-read`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription)
            store.upsertItems(listOf(item(1), item(2, isFavorite = true)))

            val model = listModel(RssItemScope.Subscription("s1"))
            advanceUntilIdle()
            assertEquals(1, model.state.value.listEpoch, "the open (its sync re-reads the same list)")

            model.setOrdering(RssOrderingMode.NEWEST_FIRST)
            advanceUntilIdle()
            assertEquals(2, model.state.value.listEpoch, "an ordering change")

            model.setFilter(RssItemFilter.ALL)
            advanceUntilIdle()
            assertEquals(3, model.state.value.listEpoch, "a filter change")

            model.setSearchQuery("Item")
            advanceUntilIdle()
            assertEquals(4, model.state.value.listEpoch, "a search")

            model.sync()
            advanceUntilIdle()
            model.reload()
            advanceUntilIdle()
            assertEquals(4, model.state.value.listEpoch, "a sync and a plain re-read keep the reader's place")
        }

    @Test
    fun `a folder list writes its pill to the folder row and All Feeds to the preference`() =
        runTest(dispatcher) {
            store.upsertFolder(RssFolder("d1", name = "News"))
            store.upsertSubscription(subscription.copy(folderId = "d1", defaultFilter = RssItemFilter.UNREAD))

            val folderModel = listModel(RssItemScope.Folder("d1"))
            advanceUntilIdle()
            assertEquals(RssItemFilter.UNREAD, folderModel.state.value.filter)
            folderModel.setFilter(RssItemFilter.FAVORITE)
            advanceUntilIdle()
            assertEquals(listOf("d1" to RssFolderUpdate(defaultFilter = RssItemFilter.FAVORITE)), client.folderUpdates)
            assertTrue(client.subscriptionUpdates.isEmpty())

            preferences.value = AppPreferences(feedsAllFilter = RssItemFilter.FAVORITE)
            val allModel = listModel(RssItemScope.All)
            advanceUntilIdle()
            assertEquals(RssItemFilter.FAVORITE, allModel.state.value.filter)
            allModel.setFilter(RssItemFilter.UNREAD)
            advanceUntilIdle()
            assertEquals(RssItemFilter.UNREAD, preferenceWrites.single().feedsAllFilter)
            assertEquals(1, client.folderUpdates.size)
        }

    @Test
    fun `opening an item marks it read only under the feed reader's own preference`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription.copy(defaultFilter = RssItemFilter.ALL))
            store.upsertItems(listOf(item(1)))
            val model = listModel(RssItemScope.Subscription("s1"))
            advanceUntilIdle()

            model.didOpen(
                model.state.value.items
                    .single(),
            )
            advanceUntilIdle()
            assertFalse(store.item("f1", item(1).sortKey)!!.isRead, "manual is the default")

            preferences.value = AppPreferences(markAsRead = MarkAsRead.ON_OPEN)
            model.didOpen(
                model.state.value.items
                    .single(),
            )
            advanceUntilIdle()
            assertFalse(store.item("f1", item(1).sortKey)!!.isRead, "the mail preference does not apply to feeds")

            preferences.value = AppPreferences(rssMarkAsRead = MarkAsRead.ON_OPEN)
            model.didOpen(
                model.state.value.items
                    .single(),
            )
            advanceUntilIdle()
            assertTrue(store.item("f1", item(1).sortKey)!!.isRead)
            assertTrue(
                model.state.value.items
                    .single()
                    .isRead,
            )
        }

    @Test
    fun `the reader's first render honours the feed's defaults read from the store`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription)
            store.upsertItems(listOf(item(1)))

            val model = detailModel(item(1))
            advanceUntilIdle()

            val state = model.state.value
            assertTrue(state.loaded)
            assertTrue(state.showingArticle)
            assertFalse(state.readerMode)
            assertTrue(state.remoteContentAllowed)
            assertEquals("s1", state.subscription?.subscriptionId)
        }

    @Test
    fun `the reader's toggles write one field each and a second toggle compares against the first`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription)
            store.upsertItems(listOf(item(1)))
            val model = detailModel(item(1))
            advanceUntilIdle()

            model.toggleReaderMode()
            advanceUntilIdle()
            model.toggleReaderMode()
            advanceUntilIdle()
            model.toggleRemoteContent()
            advanceUntilIdle()
            model.toggleArticle()
            advanceUntilIdle()

            assertEquals(
                listOf(
                    RssSubscriptionUpdate(defaultStyling = RssStyling.READER),
                    RssSubscriptionUpdate(defaultStyling = RssStyling.NATIVE),
                    RssSubscriptionUpdate(defaultRemoteContent = RssRemoteContentMode.HIDE),
                    RssSubscriptionUpdate(defaultOpenMode = RssOpenMode.SUMMARY),
                ),
                client.subscriptionUpdates.map { it.second },
            )
            assertEquals(RssOpenMode.SUMMARY, store.subscription("s1")?.defaultOpenMode, "the store took the change")
        }

    @Test
    fun `an item without a link never writes the open mode, and a failed write keeps the reader's state`() =
        runTest(dispatcher) {
            store.upsertSubscription(subscription)
            store.upsertItems(listOf(item(1, url = "")))
            val model = detailModel(item(1, url = ""))
            advanceUntilIdle()
            assertFalse(model.state.value.showingArticle)

            model.toggleArticle()
            advanceUntilIdle()
            assertTrue(client.subscriptionUpdates.isEmpty())

            client.failWrites = IOException("offline")
            model.toggleReaderMode()
            advanceUntilIdle()
            assertTrue(model.state.value.readerMode)
            assertEquals(
                RssStyling.READER,
                model.state.value.subscription
                    ?.defaultStyling,
                "the optimistic row stays",
            )
        }

    @Test
    fun `reader marks read on open under the feed preference and mirrors list changes`() =
        runTest(dispatcher) {
            preferences.value = AppPreferences(rssMarkAsRead = MarkAsRead.ON_OPEN)
            store.upsertSubscription(subscription.copy(defaultOpenMode = RssOpenMode.SUMMARY))
            store.upsertItems(listOf(item(1)))

            val model = detailModel(item(1))
            advanceUntilIdle()
            assertTrue(
                model.state.value.item!!
                    .isRead,
            )
            assertTrue(store.item("f1", item(1).sortKey)!!.isRead)

            events.post(FeedEvent.ItemChanged(item(1).copy(isRead = true, isFavorite = true)))
            advanceUntilIdle()
            assertTrue(
                model.state.value.item!!
                    .isFavorite,
            )
            assertNull(model.state.value.error)
        }
}
