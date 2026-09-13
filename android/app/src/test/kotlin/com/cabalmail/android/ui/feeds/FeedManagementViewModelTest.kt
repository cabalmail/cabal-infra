package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.CabalmailException
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
import com.cabalmail.kit.models.RssOpmlExport
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult
import com.cabalmail.kit.rss.InMemoryRssStore
import com.cabalmail.kit.rss.RssClient
import com.cabalmail.kit.rss.RssSyncEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
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
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** The management model against a server fake and the kit's in-memory store, mirroring the Apple `FeedManagementViewModelTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedManagementViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /** A server that keeps a catalog, so a catalog refresh sees the effect of each write. */
    private class FakeServer : RssClient {
        var folders = mutableListOf<RssFolder>()
        var subscriptions = mutableListOf<RssSubscription>()
        var subscribeError: Throwable? = null
        val subscribeCalls = mutableListOf<Pair<String, String?>>()
        val unsubscribeCalls = mutableListOf<String>()
        var nextId = 1

        override suspend fun listSubscriptions() = RssCatalog(folders.toList(), subscriptions.toList())

        override suspend fun subscribe(
            url: String,
            folderId: String?,
        ): RssSubscribeResult {
            subscribeError?.let { throw it }
            subscribeCalls += url to folderId
            subscriptions.firstOrNull { it.feedId == url }?.let { return RssSubscribeResult(it, existing = true) }
            val sub =
                RssSubscription("s${nextId++}", feedId = url, folderId = folderId.orEmpty(), dataStoreUuid = "u-$url")
            subscriptions += sub
            return RssSubscribeResult(sub, existing = false)
        }

        override suspend fun unsubscribe(subscriptionId: String): RssUnsubscribeResult {
            unsubscribeCalls += subscriptionId
            subscriptions.removeAll { it.subscriptionId == subscriptionId }
            return RssUnsubscribeResult(subscriptionId = subscriptionId)
        }

        override suspend fun updateSubscription(
            subscriptionId: String,
            update: RssSubscriptionUpdate,
        ): RssSubscription {
            val index = subscriptions.indexOfFirst { it.subscriptionId == subscriptionId }
            val updated = subscriptions[index].applying(update)
            subscriptions[index] = updated
            return updated
        }

        override suspend fun newRssFolder(
            name: String,
            parentFolderId: String?,
            displayOrder: Int?,
        ): RssFolder = RssFolder("d${nextId++}", parentFolderId.orEmpty(), name).also { folders += it }

        override suspend fun updateRssFolder(
            folderId: String,
            update: RssFolderUpdate,
        ): RssFolder {
            val index = folders.indexOfFirst { it.folderId == folderId }
            val updated = folders[index].applying(update)
            folders[index] = updated
            return updated
        }

        override suspend fun deleteRssFolder(folderId: String): RssFolderDeleteResult {
            folders.removeAll { it.folderId == folderId }
            return RssFolderDeleteResult(folderId = folderId)
        }

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

        override suspend fun getItem(
            feedId: String,
            sortKey: String,
        ): RssItem = error("unused")

        override suspend fun setItemState(changes: List<RssItemStateChange>) = changes.size

        override suspend fun markAllRead(scope: RssItemScope) = RssMarkAllReadResult(readWatermark = "w")

        override suspend fun importOpml(
            opml: String,
            folderId: String?,
        ): RssOpmlImportResult {
            folders += RssFolder("d-opml", name = "Imported")
            subscriptions += RssSubscription("s-opml", "https://opml.example/feed", folderId = "d-opml")
            return RssOpmlImportResult(created = 1, existing = 1, foldersCreated = 1)
        }

        override suspend fun exportOpml() = RssOpmlExport(opml = "<opml version=\"2.0\"/>", filename = "feeds.opml")
    }

    @TempDir
    lateinit var exportDir: File

    private val server = FakeServer()
    private val store = InMemoryRssStore()
    private val engine = RssSyncEngine(server, store)
    private val events = FeedEventBus()
    private val posted = mutableListOf<FeedEvent>()
    private val dropped = mutableListOf<String>()

    private fun model() =
        FeedManagementViewModel(
            rss = { server },
            store = store,
            engine = { engine },
            events = events,
            exportDir = exportDir,
            onDroppedProfiles = { dropped += it },
            io = dispatcher,
        )

    /**
     * Subscribes before anything is posted (the bus does not replay), on
     * the unconfined dispatcher so each post lands in [posted] as it is
     * made rather than a scheduler cycle later.
     */
    private fun kotlinx.coroutines.test.TestScope.collectEvents() {
        backgroundScope.launch(Dispatchers.Unconfined) { events.events.collect { posted += it } }
        advanceUntilIdle()
    }

    @Test
    fun `subscribe stores the server row, sends an empty folder as top level, and announces the catalog`() =
        runTest(dispatcher) {
            collectEvents()
            val model = model()

            model.subscribe("https://example.com/feed", folderId = "")
            advanceUntilIdle()

            assertEquals(listOf("https://example.com/feed" to null), server.subscribeCalls)
            assertEquals("https://example.com/feed", store.subscriptions().single().feedId)
            assertEquals(listOf<FeedEvent>(FeedEvent.CatalogChanged, FeedEvent.Changed), posted)
            val notice = model.state.value.notice as FeedNotice.Subscribed
            assertFalse(notice.existing)
            assertNull(model.state.value.sheet)
            assertFalse(model.state.value.busy)

            posted.clear()
            model.clearNotice()
            model.subscribe("https://example.com/feed", folderId = "")
            advanceUntilIdle()
            assertTrue((model.state.value.notice as FeedNotice.Subscribed).existing)
            assertEquals(listOf<FeedEvent>(FeedEvent.CatalogChanged), posted, "an existing feed pulls nothing")
        }

    @Test
    fun `unsubscribe removes the row through a catalog refresh and drops its web profile`() =
        runTest(dispatcher) {
            val model = model()
            model.subscribe("https://a.example/feed", "")
            advanceUntilIdle()
            val sub = store.subscriptions().single()

            model.unsubscribe(sub)
            advanceUntilIdle()

            assertEquals(listOf(sub.subscriptionId), server.unsubscribeCalls)
            assertNull(store.subscription(sub.subscriptionId))
            assertEquals(listOf("u-https://a.example/feed"), dropped)
            assertEquals(FeedNotice.Unsubscribed, model.state.value.notice)
        }

    @Test
    fun `update writes the server's version and the folder lifecycle goes through the catalog`() =
        runTest(dispatcher) {
            collectEvents()
            val model = model()
            model.subscribe("https://a.example/feed", "")
            advanceUntilIdle()
            val sub = store.subscriptions().single()

            model.updateSubscription(
                sub,
                RssSubscriptionUpdate(customTitle = "Mine", orderingMode = RssOrderingMode.OLDEST_FIRST),
            )
            advanceUntilIdle()
            assertEquals("Mine", store.subscription(sub.subscriptionId)?.displayTitle)
            assertEquals(RssOrderingMode.OLDEST_FIRST, store.subscription(sub.subscriptionId)?.orderingMode)

            posted.clear()
            model.createFolder(" Tech ", "")
            advanceUntilIdle()
            assertEquals(listOf("Tech"), store.folders().map { it.name })
            val folder = store.folders().single()
            model.updateFolder(folder, RssFolderUpdate(name = "Technology"))
            advanceUntilIdle()
            assertEquals(listOf("Technology"), store.folders().map { it.name })
            model.deleteFolder(store.folders().single())
            advanceUntilIdle()
            assertTrue(store.folders().isEmpty())
            assertEquals(3, posted.count { it == FeedEvent.CatalogChanged })
        }

    @Test
    fun `a server error maps to a sentence, leaves the store alone, and clears busy`() =
        runTest(dispatcher) {
            collectEvents()
            server.subscribeError = CabalmailException.ApiError(400, "no feed", code = "not_a_feed")
            val model = model()
            model.openSubscribe()
            model.subscribe("https://nope.example", "")
            advanceUntilIdle()

            assertEquals(
                "That address didn't return a feed, and the page doesn't advertise one.",
                model.state.value.error,
            )
            assertTrue(store.subscriptions().isEmpty())
            assertTrue(posted.isEmpty())
            assertFalse(model.state.value.busy)
            assertTrue(model.state.value.sheet is FeedSheet.Subscribe, "the sheet stays open on failure")
        }

    @Test
    fun `import refreshes the catalog and reports counts, export writes the file`() =
        runTest(dispatcher) {
            val model = model()
            model.importOpml("<opml/>", folderId = null)
            advanceUntilIdle()

            val notice = model.state.value.notice as FeedNotice.OpmlImported
            assertEquals(
                "1 new feed, 1 feed already subscribed, 1 folder created.",
                FeedOpmlSummary.text(notice.result),
            )
            assertEquals(listOf("Imported"), store.folders().map { it.name })
            assertEquals(1, store.subscriptions().size)

            model.clearNotice()
            model.exportOpml()
            advanceUntilIdle()
            val exported = model.state.value.notice as FeedNotice.OpmlExported
            assertEquals("feeds.opml", exported.file.name)
            assertTrue(exported.file.readText().contains("opml"))
        }

    @Test
    fun `mark all read for a folder scope goes store first and posts a broad change`() =
        runTest(dispatcher) {
            collectEvents()
            val model = model()
            model.createFolder("News", "")
            advanceUntilIdle()
            val folder = store.folders().single()
            model.subscribe("https://a.example/feed", folder.folderId)
            advanceUntilIdle()
            val sub = store.subscriptions().single()
            store.upsertItems(
                listOf(
                    RssItem(sub.feedId, "2026-01-01T00:00:00+00:00#i1", publishedAt = "2026-01-01T00:00:00+00:00"),
                ),
            )
            posted.clear()

            model.markAllRead(RssItemScope.Folder(folder.folderId))
            advanceUntilIdle()

            assertEquals(emptyMap<String, Int>(), store.unreadCounts())
            assertEquals(listOf<FeedEvent>(FeedEvent.Changed), posted)
            assertNull(model.state.value.confirm)
        }
}
