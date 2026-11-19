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
import com.cabalmail.kit.models.RssOpmlExport
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssStateSyncPage
import com.cabalmail.kit.models.RssSubscribeResult
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.models.RssSyncPage
import com.cabalmail.kit.models.RssUnsubscribeResult
import com.cabalmail.kit.rss.InMemoryRssStore
import com.cabalmail.kit.rss.RssClient
import com.cabalmail.kit.rss.RssFlagRefusal
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.FlagPalette
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
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * Flags on feed items through the two feed view models, over the kit's
 * real engine and in-memory store (`docs/1.x/cross-media-ux-plan.md`,
 * Phase 2b): what a press of a flag shows, writes and sends from the list
 * and from the reader, that each screen follows the other, and that a flag
 * the server refuses leaves both.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedItemFlagsViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /**
     * The item-state endpoint as the server answers it: a call that adds a
     * slot its [palette] does not hold is refused whole. Syncs answer
     * empty pages.
     */
    private class FlagServer : RssClient {
        val palette = mutableSetOf<String>()
        val calls = mutableListOf<List<RssItemStateChange>>()
        var unreachable = false

        override suspend fun setItemState(changes: List<RssItemStateChange>): Int {
            if (unreachable) throw IOException("unreachable")
            calls += changes
            val refused = changes.flatMap { it.addFlags }.toSet() - palette
            if (refused.isNotEmpty()) throw RssFlagRefusal(refused, "Not a flag in the palette.")
            return changes.size
        }

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

    private val later = "cabal-flag-01"
    private val work = "cabal-flag-02"

    private val store = InMemoryRssStore()
    private val server = FlagServer().apply { palette += listOf(later, work) }
    private val engine = RssSyncEngine(server, store)
    private val events = FeedEventBus()
    private val preferences = MutableStateFlow(AppPreferences())
    private val subscription = RssSubscription(subscriptionId = "s1", feedId = "f1", defaultFilter = RssItemFilter.ALL)
    private val scope = RssItemScope.Subscription("s1")

    private fun item(n: Int) =
        RssItem(
            feedId = "f1",
            sortKey = "2026-01-0${n}T10:00:00+00:00#i$n",
            itemId = "i$n",
            title = "Item $n",
            publishedAt = "2026-01-0${n}T10:00:00+00:00",
            summaryHtml = "<p>$n</p>",
        )

    private suspend fun seed(vararg items: RssItem) {
        store.upsertSubscription(subscription)
        store.upsertItems(items.toList())
    }

    private fun listModel() =
        FeedItemListViewModel(
            scope = scope,
            store = store,
            engine = { engine },
            events = events,
            preferences = preferences,
            updatePreferences = { transform -> preferences.value = transform(preferences.value) },
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

    private fun FeedItemListViewModel.row(item: RssItem) = state.value.items.first { it.id == item.id }

    private suspend fun stored(item: RssItem) = store.item(item.feedId, item.sortKey)!!

    // ------------------------------------------------------------- the list

    @Test
    fun `a flag of the user's own set from the list is on the row, in the store and sent`() =
        runTest(dispatcher) {
            seed(item(1), item(2))
            val list = listModel()
            advanceUntilIdle()
            server.calls.clear()

            list.setFlag(list.row(item(1)), later, true)

            assertEquals(setOf(later), list.row(item(1)).flags, "shown before anything is written")
            advanceUntilIdle()
            assertEquals(setOf(later), list.row(item(1)).flags)
            assertEquals(emptySet<String>(), list.row(item(2)).flags)
            assertEquals(setOf(later), stored(item(1)).flags)
            assertFalse(stored(item(1)).isFavorite, "the built-in flag is another mark")
            assertEquals(
                listOf(RssItemStateChange("f1", item(1).sortKey, addFlags = setOf(later))),
                server.calls.single(),
            )
            assertEquals(emptySet<String>(), list.state.value.pendingIds)

            list.setFlag(list.row(item(1)), later, false)
            advanceUntilIdle()
            assertEquals(emptySet<String>(), list.row(item(1)).flags)
            assertEquals(
                setOf(later),
                server.calls
                    .last()
                    .single()
                    .removeFlags,
            )
        }

    @Test
    fun `the built-in flag's slot sets the favorite mark, as it always did`() =
        runTest(dispatcher) {
            seed(item(1))
            val list = listModel()
            advanceUntilIdle()
            server.calls.clear()

            list.setFlag(list.row(item(1)), FlagPalette.SYSTEM_SLOT, true)
            advanceUntilIdle()

            assertTrue(list.row(item(1)).isFavorite)
            assertEquals(emptySet<String>(), list.row(item(1)).flags)
            assertEquals(listOf(RssItemStateChange("f1", item(1).sortKey, isFavorite = true)), server.calls.single())
        }

    @Test
    fun `a flag set while the server cannot be reached stays on the row with the queued mark`() =
        runTest(dispatcher) {
            seed(item(1))
            val list = listModel()
            advanceUntilIdle()
            server.unreachable = true

            list.setFlag(list.row(item(1)), work, true)
            advanceUntilIdle()

            assertEquals(setOf(work), list.row(item(1)).flags)
            assertEquals(setOf(item(1).id), list.state.value.pendingIds)
        }

    @Test
    fun `a flag the server refuses leaves the row again`() =
        runTest(dispatcher) {
            seed(item(1))
            val list = listModel()
            advanceUntilIdle()
            // Deleted on another device since this one last heard.
            server.palette -= later

            list.setFlag(list.row(item(1)), later, true)
            assertEquals(setOf(later), list.row(item(1)).flags)
            advanceUntilIdle()

            assertEquals(emptySet<String>(), list.row(item(1)).flags, "the row is what the store holds")
            assertEquals(emptySet<String>(), stored(item(1)).flags)
            assertEquals(emptySet<String>(), list.state.value.pendingIds)
        }

    // ----------------------------------------------------------- the reader

    @Test
    fun `the reader sets and clears a flag on the open item, each press judged by the last`() =
        runTest(dispatcher) {
            seed(item(1))
            val reader = detailModel(item(1))
            advanceUntilIdle()
            server.calls.clear()

            reader.setFlag(later, true)
            advanceUntilIdle()
            reader.setFlag(work, true)
            advanceUntilIdle()

            assertEquals(
                setOf(later, work),
                reader.state.value.item!!
                    .flags,
            )
            assertEquals(setOf(later, work), stored(item(1)).flags)

            val open = reader.state.value.item!!
            reader.setFlag(later, !open.carries(later))
            advanceUntilIdle()

            assertEquals(
                setOf(work),
                reader.state.value.item!!
                    .flags,
            )
            assertEquals(
                listOf(setOf(later) to emptySet(), setOf(work) to emptySet(), emptySet<String>() to setOf(later)),
                server.calls.map { it.single().addFlags to it.single().removeFlags },
            )
        }

    @Test
    fun `the reader's built-in flag is the favorite mark`() =
        runTest(dispatcher) {
            seed(item(1))
            val reader = detailModel(item(1))
            advanceUntilIdle()

            reader.setFlag(FlagPalette.SYSTEM_SLOT, true)
            advanceUntilIdle()

            assertTrue(
                reader.state.value.item!!
                    .isFavorite,
            )
            assertTrue(stored(item(1)).isFavorite)
        }

    @Test
    fun `a flag the server refuses leaves the reader again`() =
        runTest(dispatcher) {
            seed(item(1))
            val reader = detailModel(item(1))
            advanceUntilIdle()
            server.palette.clear()

            reader.setFlag(later, true)
            advanceUntilIdle()

            assertEquals(
                emptySet<String>(),
                reader.state.value.item!!
                    .flags,
            )
        }

    // ------------------------------------------------- each follows the other

    @Test
    fun `a flag set in the reader reaches the list's row, and one set on the row reaches the reader`() =
        runTest(dispatcher) {
            seed(item(1))
            val list = listModel()
            val reader = detailModel(item(1))
            advanceUntilIdle()

            reader.setFlag(later, true)
            advanceUntilIdle()
            assertEquals(setOf(later), list.row(item(1)).flags)

            list.setFlag(list.row(item(1)), work, true)
            advanceUntilIdle()
            assertEquals(
                setOf(later, work),
                reader.state.value.item!!
                    .flags,
            )
        }

    @Test
    fun `a refused flag set in the reader leaves the list's row too`() =
        runTest(dispatcher) {
            seed(item(1))
            val list = listModel()
            val reader = detailModel(item(1))
            advanceUntilIdle()
            server.palette.clear()

            reader.setFlag(later, true)
            advanceUntilIdle()

            assertEquals(emptySet<String>(), list.row(item(1)).flags)
        }
}
