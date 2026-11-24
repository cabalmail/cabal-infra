package com.cabalmail.android.ui.flagged

import com.cabalmail.android.MailEvent
import com.cabalmail.android.MailEventBus
import com.cabalmail.android.ui.feeds.FeedEvent
import com.cabalmail.android.ui.feeds.FeedEventBus
import com.cabalmail.kit.flagged.FlaggedList
import com.cabalmail.kit.flagged.FlaggedRow
import com.cabalmail.kit.flagged.FlaggedSource
import com.cabalmail.kit.models.Envelope
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
import com.cabalmail.kit.models.SearchFilters
import com.cabalmail.kit.models.SearchResult
import com.cabalmail.kit.rss.InMemoryRssStore
import com.cabalmail.kit.rss.RssClient
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.MarkAsRead
import kotlinx.coroutines.CompletableDeferred
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
 * The Flagged view's model (`docs/1.x/post-wave-3/android-parity.md`, leg
 * L4) against a scripted mail search and the kit's real feed engine over
 * its in-memory store: what each pick asks of each half, what the list
 * shows while mail is still paging, what it shows when mail cannot be had,
 * and what a row's writes do.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FlaggedViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterEach
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private data class Search(
        val filters: SearchFilters,
        val cursor: String?,
        val limit: Int,
    )

    private data class FlagWrite(
        val folder: String,
        val uid: Long,
        val flag: String,
        val value: Boolean,
        val flagsAfter: List<String>,
    )

    private data class Move(
        val folder: String,
        val uid: Long,
        val destination: String,
        val markSeen: Boolean,
    )

    /** The mail half as a script: what each search is answered with, and a record of every call. */
    private class ScriptedMail : FlaggedMail {
        val searches = mutableListOf<Search>()
        val flagWrites = mutableListOf<FlagWrite>()
        val moves = mutableListOf<Move>()
        val purges = mutableListOf<Pair<String, Long>>()

        /** The answer to a search; the default is one empty, final page. */
        var answer: suspend (Search) -> SearchResult = { SearchResult() }
        var writeFailure: Throwable? = null

        /** When set, a write waits on it, so a test can act while one is in flight. */
        var writeGate: CompletableDeferred<Unit>? = null

        override suspend fun search(
            filters: SearchFilters,
            cursor: String?,
            limit: Int,
        ): SearchResult {
            val search = Search(filters, cursor, limit)
            searches += search
            return answer(search)
        }

        override suspend fun setFlag(
            folder: String,
            patched: Envelope,
            flag: String,
            value: Boolean,
        ) {
            flagWrites += FlagWrite(folder, patched.id, flag, value, patched.flags)
            writeGate?.await()
            writeFailure?.let { throw it }
        }

        override suspend fun move(
            folder: String,
            uid: Long,
            destination: String,
            markSeen: Boolean,
        ) {
            moves += Move(folder, uid, destination, markSeen)
            writeGate?.await()
            writeFailure?.let { throw it }
        }

        override suspend fun purge(
            folder: String,
            uid: Long,
        ) {
            purges += folder to uid
            writeGate?.await()
            writeFailure?.let { throw it }
        }
    }

    /** Records item-state calls; answers syncs with empty pages so the engine's loops end at once. */
    private class RecordingFeedClient : RssClient {
        val stateCalls = mutableListOf<List<RssItemStateChange>>()

        override suspend fun setItemState(changes: List<RssItemStateChange>): Int {
            stateCalls += changes
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
    private val builtIn = FlagPalette.SYSTEM_SLOT

    private val mail = ScriptedMail()
    private val store = InMemoryRssStore()
    private val feedClient = RecordingFeedClient()
    private val engine = RssSyncEngine(feedClient, store)
    private val feedEvents = FeedEventBus()
    private val mailEvents = MailEventBus()
    private val preferences = MutableStateFlow(AppPreferences())
    private var feedSyncs = 0

    private fun model() =
        FlaggedViewModel(
            mail = mail,
            store = store,
            engine = { engine },
            syncFeeds = { feedSyncs++ },
            feedEvents = feedEvents,
            mailEvents = mailEvents.events,
            preferences = preferences,
        )

    private fun message(
        uid: Long,
        date: String,
        folder: String = "INBOX",
        flags: List<String> = listOf(builtIn),
    ) = Envelope(id = uid, date = date, folder = folder, flags = flags, subject = "m$uid")

    private fun article(
        n: Int,
        isFavorite: Boolean = true,
        flags: Set<String> = emptySet(),
        day: String = "2026-03-0$n",
    ) = RssItem(
        feedId = "f1",
        sortKey = "${day}T12:00:00+00:00#a$n",
        itemId = "a$n",
        title = "Article $n",
        url = "https://example.com/$n",
        publishedAt = "${day}T12:00:00+00:00",
        isFavorite = isFavorite,
        flags = flags,
    )

    private suspend fun seedFeed(vararg items: RssItem) {
        store.upsertSubscription(RssSubscription("s1", "f1"))
        store.upsertItems(items.toList())
    }

    /** Each row as `m<uid>` or the feed item's id, in list order. */
    private fun FlaggedViewModel.shown(): List<String> =
        state.value.page.rows.map { row ->
            when (row) {
                is FlaggedRow.Mail -> "m${row.envelope.id}"
                is FlaggedRow.Feed -> row.item.itemId
            }
        }

    @Test
    fun `the view opens on any flag, with both media in one list by date`() =
        runTest(dispatcher) {
            seedFeed(article(2), article(4, isFavorite = false, flags = setOf(later)), article(5, isFavorite = false))
            mail.answer = {
                SearchResult(
                    envelopes = listOf(message(9, "2026-03-05 08:00:00"), message(7, "2026-03-03 08:00:00", "Archive")),
                    foldersSearched = listOf("INBOX", "Archive"),
                )
            }

            val model = model()
            advanceUntilIdle()

            // One request, across folders, for any flag, at the server's largest page.
            assertEquals(listOf(Search(SearchFilters(anyFlag = true), null, FlaggedList.MAIL_PAGE_SIZE)), mail.searches)
            // The unflagged article is not there; the rest interleave.
            assertEquals(listOf("m9", "a4", "m7", "a2"), model.shown())
            assertEquals(listOf("INBOX", "Archive"), model.state.value.foldersSearched)
            assertNull(model.state.value.page.cutoff)
            assertFalse(model.state.value.isEmpty)
            assertEquals(1, feedSyncs, "the device's feed items are brought up to date once, on open")
        }

    @Test
    fun `nothing is listed until the first page of mail lands`() =
        runTest(dispatcher) {
            seedFeed(article(2))
            val gate = CompletableDeferred<SearchResult>()
            mail.answer = { gate.await() }

            val model = model()
            advanceUntilIdle()

            // The feed half is read, and waits: mail may belong above it.
            assertTrue(model.state.value.feedLoaded)
            assertTrue(model.state.value.mailLoading)
            assertEquals(emptyList<String>(), model.shown())
            assertFalse(model.state.value.isEmpty, "still loading is not empty")

            gate.complete(SearchResult(envelopes = listOf(message(9, "2026-03-05 08:00:00"))))
            advanceUntilIdle()
            assertEquals(listOf("m9", "a2"), model.shown())
            assertFalse(model.state.value.mailLoading)
        }

    @Test
    fun `nothing flagged anywhere is the empty state, and only then`() =
        runTest(dispatcher) {
            seedFeed(article(1, isFavorite = false))
            val model = model()
            advanceUntilIdle()
            assertTrue(model.state.value.isEmpty)
            assertEquals(emptyList<String>(), model.shown())
        }

    @Test
    fun `a pick asks each half for that flag and starts the list over`() =
        runTest(dispatcher) {
            seedFeed(article(1), article(2, isFavorite = false, flags = setOf(later)), article(3, flags = setOf(later)))
            val both = message(8, "2026-03-08 08:00:00", flags = listOf(builtIn, later))
            val star = message(7, "2026-03-07 08:00:00")
            val tagged = message(6, "2026-03-06 08:00:00", flags = listOf(later))
            mail.answer = { search ->
                when (search.filters) {
                    SearchFilters(anyFlag = true) -> SearchResult(listOf(both, star, tagged))
                    SearchFilters(keyword = later) -> SearchResult(listOf(both, tagged))
                    SearchFilters(flagged = true) -> SearchResult(listOf(both, star))
                    else -> error("unexpected search ${search.filters}")
                }
            }
            val model = model()
            advanceUntilIdle()
            assertEquals(listOf("m8", "m7", "m6", "a3", "a2", "a1"), model.shown())
            val epoch = model.state.value.listEpoch

            model.pick(FlagCriterion.Slot(later))
            advanceUntilIdle()
            assertEquals(SearchFilters(keyword = later), mail.searches.last().filters)
            assertEquals(listOf("m8", "m6", "a3", "a2"), model.shown())
            assertEquals(epoch + 1, model.state.value.listEpoch, "a fresh list, from the top")

            model.pick(FlagCriterion.Slot(builtIn))
            advanceUntilIdle()
            assertEquals(SearchFilters(flagged = true), mail.searches.last().filters)
            assertEquals(listOf("m8", "m7", "a3", "a1"), model.shown())

            // The same pick again asks nothing.
            val asked = mail.searches.size
            model.pick(FlagCriterion.Slot(builtIn))
            advanceUntilIdle()
            assertEquals(asked, mail.searches.size)

            model.pick(FlagCriterion.AnyFlag)
            advanceUntilIdle()
            assertEquals(listOf("m8", "m7", "m6", "a3", "a2", "a1"), model.shown())
        }

    @Test
    fun `a reply to the list a pick replaced is not shown`() =
        runTest(dispatcher) {
            val slow = CompletableDeferred<SearchResult>()
            mail.answer = { search ->
                if (search.filters == SearchFilters(anyFlag = true)) {
                    slow.await()
                } else {
                    SearchResult(listOf(message(6, "2026-03-06 08:00:00", flags = listOf(later))))
                }
            }
            val model = model()
            advanceUntilIdle()

            model.pick(FlagCriterion.Slot(later))
            advanceUntilIdle()
            assertEquals(listOf("m6"), model.shown())

            // The first request answers late, with a message the pick would not find.
            slow.complete(SearchResult(listOf(message(7, "2026-03-07 08:00:00"))))
            advanceUntilIdle()
            assertEquals(listOf("m6"), model.shown())
            assertEquals(FlagCriterion.Slot(later), model.state.value.criterion)
        }

    @Test
    fun `while mail has more pages the list ends at its horizon, and the end of the list loads the next`() =
        runTest(dispatcher) {
            seedFeed(article(6), article(5), article(1))
            mail.answer = { search ->
                when (search.cursor) {
                    null ->
                        SearchResult(
                            envelopes = listOf(message(9, "2026-03-07 08:00:00"), message(8, "2026-03-05 20:00:00")),
                            nextCursor = "page-2",
                        )
                    "page-2" ->
                        SearchResult(
                            envelopes =
                                listOf(
                                    message(7, "2026-03-05 06:00:00", "Archive"),
                                    message(6, "2026-03-02 08:00:00"),
                                ),
                        )
                    else -> error("unexpected cursor ${search.cursor}")
                }
            }
            val model = model()
            advanceUntilIdle()

            // The page ended inside 5 March: that day and everything older waits, from both media.
            assertEquals(listOf("m9", "a6"), model.shown())
            assertEquals(FlaggedSource.MAIL, model.state.value.page.next)
            assertEquals(3, model.state.value.page.heldBack)

            model.loadMore()
            advanceUntilIdle()
            assertEquals(listOf(null, "page-2"), mail.searches.map { it.cursor })
            assertEquals(listOf("m9", "a6", "m8", "a5", "m7", "m6", "a1"), model.shown())
            assertNull(model.state.value.page.next)

            // The end of a whole list asks for nothing.
            model.loadMore()
            advanceUntilIdle()
            assertEquals(2, mail.searches.size)
        }

    @Test
    fun `a message the server delivers on two pages is listed once`() =
        runTest(dispatcher) {
            val twice = message(8, "2026-03-05 20:00:00")
            mail.answer = { search ->
                if (search.cursor == null) {
                    SearchResult(listOf(message(9, "2026-03-07 08:00:00"), twice), nextCursor = "page-2")
                } else {
                    // The same UID in another folder is another message.
                    SearchResult(listOf(twice, message(8, "2026-03-05 10:00:00", "Archive")))
                }
            }
            val model = model()
            advanceUntilIdle()
            model.loadMore()
            advanceUntilIdle()
            assertEquals(3, model.state.value.mail.size)
            assertEquals(3, model.shown().size)
        }

    @Test
    fun `offline on open the flagged feed items stand alone, and Retry brings the mail`() =
        runTest(dispatcher) {
            seedFeed(article(2), article(1))
            var offline = true
            mail.answer = {
                if (offline) throw IOException("no route") else SearchResult(listOf(message(9, "2026-03-01 20:00:00")))
            }
            val model = model()
            advanceUntilIdle()

            assertEquals(FlaggedMailFailure.NEVER_LOADED, model.state.value.mailFailure)
            // No horizon: nothing is claimed about mail, so every feed item shows.
            assertEquals(listOf("a2", "a1"), model.shown())
            assertNull(model.state.value.page.cutoff)
            assertFalse(model.state.value.isEmpty)

            offline = false
            model.retryMail()
            advanceUntilIdle()
            assertNull(model.state.value.mailFailure)
            assertEquals(listOf("a2", "m9", "a1"), model.shown())
        }

    @Test
    fun `offline with nothing flagged on the device is a failure, not an empty list`() =
        runTest(dispatcher) {
            mail.answer = { throw IOException("no route") }
            val model = model()
            advanceUntilIdle()
            assertEquals(FlaggedMailFailure.NEVER_LOADED, model.state.value.mailFailure)
            assertFalse(model.state.value.isEmpty)
        }

    @Test
    fun `a retry in flight with nothing on the device is not yet an empty list`() =
        runTest(dispatcher) {
            var gate: CompletableDeferred<SearchResult>? = null
            mail.answer = { gate?.await() ?: throw IOException("no route") }
            val model = model()
            advanceUntilIdle()
            assertEquals(FlaggedMailFailure.NEVER_LOADED, model.state.value.mailFailure)

            gate = CompletableDeferred()
            model.retryMail()
            advanceUntilIdle()
            assertTrue(model.state.value.mailLoading)
            assertFalse(model.state.value.isEmpty, "the answer is not in")

            gate.complete(SearchResult())
            advanceUntilIdle()
            assertTrue(model.state.value.isEmpty)
        }

    @Test
    fun `a refresh that fails keeps the messages already on screen`() =
        runTest(dispatcher) {
            seedFeed(article(1))
            var offline = false
            mail.answer = {
                if (offline) throw IOException("no route") else SearchResult(listOf(message(9, "2026-03-05 08:00:00")))
            }
            val model = model()
            advanceUntilIdle()
            assertEquals(listOf("m9", "a1"), model.shown())

            offline = true
            model.refresh()
            advanceUntilIdle()

            assertEquals(FlaggedMailFailure.REFRESH, model.state.value.mailFailure)
            assertEquals(listOf("m9", "a1"), model.shown())
            assertFalse(model.state.value.refreshing)
            assertEquals(2, feedSyncs, "a refresh brings the feed half up to date too")
        }

    @Test
    fun `a refresh takes the server's new first page in place of the old list`() =
        runTest(dispatcher) {
            var current = listOf(message(9, "2026-03-05 08:00:00"), message(8, "2026-03-04 08:00:00"))
            mail.answer = { SearchResult(current) }
            val model = model()
            advanceUntilIdle()
            assertEquals(listOf("m9", "m8"), model.shown())

            // Unflagged on another device, and a newer one flagged.
            current = listOf(message(10, "2026-03-06 08:00:00"), message(9, "2026-03-05 08:00:00"))
            model.refresh()
            advanceUntilIdle()
            assertEquals(listOf("m10", "m9"), model.shown())
        }

    @Test
    fun `a next page that fails leaves the list at its horizon until Retry asks for that page again`() =
        runTest(dispatcher) {
            seedFeed(article(1))
            var offline = false
            mail.answer = { search ->
                when {
                    search.cursor == null ->
                        SearchResult(
                            listOf(message(9, "2026-03-07 08:00:00"), message(8, "2026-03-05 20:00:00")),
                            nextCursor = "p2",
                        )
                    offline -> throw IOException("no route")
                    else -> SearchResult(listOf(message(7, "2026-03-04 08:00:00")))
                }
            }
            val model = model()
            advanceUntilIdle()

            offline = true
            model.loadMore()
            advanceUntilIdle()
            assertEquals(FlaggedMailFailure.NEXT_PAGE, model.state.value.mailFailure)
            assertEquals(listOf("m9"), model.shown(), "what was held back is still held back")

            // The end of the list is still on screen; it must not ask in a loop.
            val asked = mail.searches.size
            model.loadMore()
            advanceUntilIdle()
            assertEquals(asked, mail.searches.size)

            offline = false
            model.retryMail()
            advanceUntilIdle()
            assertEquals("p2", mail.searches.last().cursor, "the page that failed, not the first")
            assertEquals(listOf("m9", "m8", "m7", "a1"), model.shown())
            assertNull(model.state.value.mailFailure)
        }

    @Test
    fun `the server's cap is passed on`() =
        runTest(dispatcher) {
            mail.answer = { SearchResult(listOf(message(9, "2026-03-07 08:00:00")), truncated = true) }
            val model = model()
            advanceUntilIdle()
            assertTrue(model.state.value.truncated)
            assertEquals(listOf("m9"), model.shown())
        }

    @Test
    fun `a slot no message can carry is never sent to the server`() =
        runTest(dispatcher) {
            val model = model()
            advanceUntilIdle()
            val asked = mail.searches.size

            model.pick(FlagCriterion.Slot("cabal-flag-99"))
            advanceUntilIdle()
            assertEquals(asked, mail.searches.size)
            assertTrue(model.state.value.isEmpty)
        }

    @Test
    fun `a message whose flag is cleared leaves at once, and the write names its own folder`() =
        runTest(dispatcher) {
            val archived = message(7, "2026-03-03 08:00:00", "Archive")
            val two = message(9, "2026-03-05 08:00:00", flags = listOf(builtIn, later, "\\Seen"))
            mail.answer = { SearchResult(listOf(two, archived)) }
            val model = model()
            advanceUntilIdle()
            val searches = mail.searches.size

            model.setMailFlag(archived, builtIn, false)
            advanceUntilIdle()
            assertEquals(listOf("m9"), model.shown())
            assertEquals(listOf(FlagWrite("Archive", 7, builtIn, false, emptyList())), mail.flagWrites)

            // Under any flag, a message that keeps another flag stays.
            model.setMailFlag(two, builtIn, false)
            advanceUntilIdle()
            assertEquals(listOf("m9"), model.shown())
            assertEquals(listOf(later, "\\Seen"), mail.flagWrites.last().flagsAfter)
            assertEquals(searches, mail.searches.size, "a write that worked asks the server nothing more")
        }

    @Test
    fun `marking a message read leaves it in the list`() =
        runTest(dispatcher) {
            val unread = message(9, "2026-03-05 08:00:00")
            mail.answer = { SearchResult(listOf(unread)) }
            val model = model()
            advanceUntilIdle()

            model.toggleSeen(unread)
            advanceUntilIdle()
            assertEquals(listOf("m9"), model.shown())
            assertEquals(FlagWrite("INBOX", 9, "\\Seen", true, listOf(builtIn, "\\Seen")), mail.flagWrites.single())
            assertTrue(
                model.state.value.mail
                    .single()
                    .isSeen,
            )
        }

    @Test
    fun `a flag write that fails is reported and the list is read again`() =
        runTest(dispatcher) {
            val message = message(9, "2026-03-05 08:00:00")
            mail.answer = { SearchResult(listOf(message)) }
            val model = model()
            advanceUntilIdle()

            mail.writeFailure = IOException("no route")
            model.setMailFlag(message, builtIn, false)
            advanceUntilIdle()

            assertTrue(model.state.value.error != null)
            assertEquals(2, mail.searches.size)
            // The server still holds the flag, so the row is back.
            assertEquals(listOf("m9"), model.shown())
        }

    @Test
    fun `a dispose resolves against the row's own folder`() =
        runTest(dispatcher) {
            val inbox = message(9, "2026-03-05 08:00:00", "INBOX")
            val archived = message(8, "2026-03-04 08:00:00", "Archive")
            val trashed = message(7, "2026-03-03 08:00:00", "Trash")
            val filed = message(6, "2026-03-02 08:00:00", "Receipts")
            mail.answer = { SearchResult(listOf(inbox, archived, trashed, filed)) }
            val model = model()
            advanceUntilIdle()

            model.dispose(inbox)
            model.dispose(archived)
            model.dispose(trashed)
            advanceUntilIdle()

            assertEquals(
                listOf(
                    // Archived is read, in the same call.
                    Move("INBOX", 9, "Archive", markSeen = true),
                    // Archiving from Archive would move it onto itself: back to the inbox, read state alone.
                    Move("Archive", 8, "INBOX", markSeen = false),
                ),
                mail.moves,
            )
            assertEquals(listOf("Trash" to 7L), mail.purges)
            assertEquals(listOf("m6"), model.shown())

            // The preference names the destination everywhere else.
            preferences.value = preferences.value.copy(disposeAction = DisposeAction.TRASH)
            model.dispose(filed)
            advanceUntilIdle()
            assertEquals(Move("Receipts", 6, "Trash", markSeen = true), mail.moves.last())
        }

    @Test
    fun `a second dispose of a message whose move is in flight is dropped`() =
        runTest(dispatcher) {
            val message = message(9, "2026-03-05 08:00:00")
            mail.answer = { SearchResult(listOf(message)) }
            val model = model()
            advanceUntilIdle()

            val gate = CompletableDeferred<Unit>()
            mail.writeGate = gate
            model.dispose(message)
            advanceUntilIdle()
            model.dispose(message)
            advanceUntilIdle()
            assertEquals(1, mail.moves.size, "two moves of one message land two copies in the destination")

            gate.complete(Unit)
            advanceUntilIdle()
            assertEquals(1, mail.moves.size)
        }

    @Test
    fun `a dispose that fails is reported and the list is read again`() =
        runTest(dispatcher) {
            val message = message(9, "2026-03-05 08:00:00")
            mail.answer = { SearchResult(listOf(message)) }
            val model = model()
            advanceUntilIdle()

            mail.writeFailure = IOException("no route")
            model.dispose(message)
            advanceUntilIdle()
            assertTrue(model.state.value.error != null)
            assertEquals(listOf("m9"), model.shown(), "it never left its folder")
        }

    @Test
    fun `the list follows what a reader does to a message`() =
        runTest(dispatcher) {
            val a = message(9, "2026-03-05 08:00:00")
            val b = message(9, "2026-03-04 08:00:00", "Archive")
            val c = message(5, "2026-03-03 08:00:00")
            val d = message(5, "2026-03-02 08:00:00", "Receipts")
            mail.answer = { SearchResult(listOf(a, b, c, d)) }
            val model = model()
            advanceUntilIdle()

            // Unflagged in the reader: that folder's message, not its namesake's.
            mailEvents.emit(MailEvent.FlagChanged("INBOX", setOf(9), builtIn, false))
            advanceUntilIdle()
            assertEquals(listOf("m9", "m5", "m5"), model.shown())
            assertEquals(
                "Archive",
                (
                    model.state.value.page.rows
                        .first() as FlaggedRow.Mail
                ).envelope.folder,
            )

            // Archived from the reader: again that folder's message alone.
            mailEvents.emit(MailEvent.Removed("INBOX", setOf(5), "Archive"))
            advanceUntilIdle()
            assertEquals(listOf("m9", "m5"), model.shown())
            assertEquals(
                listOf("Archive", "Receipts"),
                model.state.value.page.rows
                    .map { (it as FlaggedRow.Mail).envelope.folder },
            )

            // A failed write elsewhere in a folder the list shows: read it again. One it does not show: nothing.
            val asked = mail.searches.size
            mailEvents.emit(MailEvent.Reconcile("Sent"))
            advanceUntilIdle()
            assertEquals(asked, mail.searches.size)
            mailEvents.emit(MailEvent.Reconcile("Archive"))
            advanceUntilIdle()
            assertEquals(asked + 1, mail.searches.size)
        }

    @Test
    fun `a feed item's flag is written through the queue, and a cleared one stays until the half is read again`() =
        runTest(dispatcher) {
            seedFeed(article(2), article(1))
            val model = model()
            advanceUntilIdle()
            val item =
                model.state.value.feed
                    .first { it.itemId == "a2" }

            model.setFeedFlag(item, builtIn, false)
            advanceUntilIdle()

            // Sent, and stored, as the feed list's own flag control does it.
            assertEquals(
                false,
                feedClient.stateCalls
                    .flatten()
                    .single()
                    .isFavorite,
            )
            assertFalse(store.item("f1", item.sortKey)!!.isFavorite)
            // The row stays, drawn without its flag, as under a feed's Flagged pill.
            assertEquals(listOf("a2", "a1"), model.shown())
            assertFalse(
                model.state.value.feed
                    .first { it.itemId == "a2" }
                    .isFavorite,
            )

            // A sync, or anything else that reads the half again, drops it.
            feedEvents.post(FeedEvent.Changed)
            advanceUntilIdle()
            assertEquals(listOf("a1"), model.shown())
        }

    @Test
    fun `the list follows what a reader does to a feed item`() =
        runTest(dispatcher) {
            seedFeed(article(2), article(1))
            val model = model()
            advanceUntilIdle()
            val item =
                model.state.value.feed
                    .first { it.itemId == "a1" }

            feedEvents.post(FeedEvent.ItemChanged(item.copy(isRead = true, flags = setOf(later))))
            advanceUntilIdle()
            val row =
                model.state.value.feed
                    .first { it.itemId == "a1" }
            assertTrue(row.isRead)
            assertEquals(setOf(later), row.flags)
        }

    @Test
    fun `opening a feed item marks it read only when the feed reader's preference says so`() =
        runTest(dispatcher) {
            seedFeed(article(2), article(1))
            preferences.value = preferences.value.copy(rssMarkAsRead = MarkAsRead.MANUAL)
            val model = model()
            advanceUntilIdle()
            val first =
                model.state.value.feed
                    .first { it.itemId == "a2" }

            model.didOpen(first)
            advanceUntilIdle()
            assertFalse(store.item("f1", first.sortKey)!!.isRead)

            preferences.value = preferences.value.copy(rssMarkAsRead = MarkAsRead.ON_OPEN)
            model.didOpen(first)
            advanceUntilIdle()
            assertTrue(store.item("f1", first.sortKey)!!.isRead)
            assertEquals(listOf("a2", "a1"), model.shown(), "read is not unflagged")
        }

    @Test
    fun `more flagged feed items than one read holds are paged behind a horizon of their own`() =
        runTest(dispatcher) {
            store.upsertSubscription(RssSubscription("s1", "f1"))
            val count = FlaggedList.FEED_PAGE_SIZE + 5
            // One a minute, newest first by index.
            val items =
                (0 until count).map { n ->
                    val stamp = "2026-03-01T%02d:%02d:00+00:00".format(23 - n / 60, 59 - n % 60)
                    RssItem(
                        feedId = "f1",
                        sortKey = "$stamp#a$n",
                        itemId = "a$n",
                        publishedAt = stamp,
                        isFavorite = true,
                    )
                }
            store.upsertItems(items)
            val model = model()
            advanceUntilIdle()

            // The last row read may share its instant with one not read yet, so it waits with the rest.
            assertEquals(FlaggedList.FEED_PAGE_SIZE - 1, model.shown().size)
            assertEquals(FlaggedSource.FEED, model.state.value.page.next)

            model.loadMore()
            advanceUntilIdle()
            assertEquals(count, model.shown().size)
            assertEquals("a${count - 1}", model.shown().last())
            assertNull(model.state.value.page.next)
        }
}
