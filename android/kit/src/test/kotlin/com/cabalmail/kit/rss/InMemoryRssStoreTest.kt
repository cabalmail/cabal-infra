package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssCatalog
import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssSubscription
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The [RssStore] contract, mirroring the Apple kit's `RssStoreTests`
 * assertion for assertion (minus the SQLite migration one). The Room
 * store's SQL is the Apple store's; this suite pins the semantics both
 * must keep.
 */
class InMemoryRssStoreTest {
    private fun sub(
        id: String,
        feedId: String,
        folderId: String = "",
        watermark: String = "",
        feed: RssFeedSummary? = null,
        dataStoreUuid: String = "uuid-$id",
    ) = RssSubscription(
        subscriptionId = id,
        feedId = feedId,
        folderId = folderId,
        readWatermark = watermark,
        dataStoreUuid = dataStoreUuid,
        feed = feed,
    )

    private fun item(
        feedId: String,
        n: Int,
        day: String = "2026-01-0$n",
        isRead: Boolean = false,
        isReadExplicit: Boolean = false,
        isFavorite: Boolean = false,
        title: String = "Item $n",
        body: String = "<p>body $n</p>",
    ) = RssItem(
        feedId = feedId,
        sortKey = "${day}T10:00:00+00:00#i$n",
        itemId = "i$n",
        title = title,
        publishedAt = "${day}T10:00:00+00:00",
        fetchedKey = "2026-02-0${n}T00:00:00+00:00#i$n",
        summaryHtml = body,
        isRead = isRead,
        isReadExplicit = isReadExplicit,
        isFavorite = isFavorite,
    )

    @Test
    fun `catalog replace upserts, removes departed rows, and reports the diff`() =
        runTest {
            val store = InMemoryRssStore()
            store.replaceCatalog(
                RssCatalog(
                    folders = listOf(RssFolder("d1", name = "Keep"), RssFolder("d2", name = "Drop")),
                    subscriptions =
                        listOf(
                            sub(
                                "s1",
                                "f1",
                                folderId = "d1",
                                watermark = "2026-01-05",
                                feed = RssFeedSummary("f1", title = "One"),
                            ),
                            sub("s2", "f2"),
                        ),
                ),
            )
            store.upsertItems(listOf(item("f1", 1), item("f2", 2)))

            val diff =
                store.replaceCatalog(
                    RssCatalog(
                        folders = listOf(RssFolder("d1", name = "Keep")),
                        subscriptions = listOf(sub("s1", "f1", folderId = "", watermark = "2026-01-01", feed = null)),
                    ),
                )

            assertEquals(CatalogDiff(listOf("s2"), listOf("uuid-s2"), listOf("f2")), diff)
            val survivor = store.subscriptions().single()
            assertEquals("", survivor.folderId)
            assertEquals("2026-01-05", survivor.readWatermark, "the watermark only advances")
            assertEquals("One", survivor.feed?.title, "a row without its feed keeps the cached summary")
            assertEquals(listOf("d1"), store.folders().map { it.folderId })
            assertEquals(0, store.itemCount("f2"))
            assertEquals(1, store.itemCount("f1"))
        }

    @Test
    fun `sticky filter and the per-feed defaults round-trip`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertFolder(RssFolder("d1", name = "News", defaultFilter = RssItemFilter.ALL))
            store.upsertSubscription(
                sub("s1", "f1").copy(
                    defaultFilter = RssItemFilter.FAVORITE,
                    defaultOpenMode = RssOpenMode.ARTICLE,
                    defaultRemoteContent = RssRemoteContentMode.HIDE,
                ),
            )
            store.upsertSubscription(sub("s2", "f2"))

            assertEquals(RssItemFilter.ALL, store.folder("d1")?.defaultFilter)
            assertEquals(RssItemFilter.FAVORITE, store.subscription("s1")?.defaultFilter)
            assertEquals(RssOpenMode.ARTICLE, store.subscription("s1")?.defaultOpenMode)
            assertEquals(RssRemoteContentMode.HIDE, store.subscription("s1")?.defaultRemoteContent)
            assertEquals(RssItemFilter.UNREAD, store.subscription("s2")?.defaultFilter)

            store.upsertFolder(store.folder("d1")!!.applying(RssFolderUpdate(defaultFilter = RssItemFilter.UNREAD)))
            assertEquals("News", store.folder("d1")?.name)
            assertEquals(RssItemFilter.UNREAD, store.folder("d1")?.defaultFilter)
        }

    @Test
    fun `read state follows the watermark unless a mark is explicit`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1", watermark = "2026-01-03T23:59:59+00:00"))
            store.upsertItems((1..5).map { item("f1", it, isRead = it == 5) })

            var listed = store.items(ItemQuery(RssItemScope.All, ordering = RssOrderingMode.OLDEST_FIRST))
            assertEquals(listOf(true, true, true, false, true), listed.map { it.isRead })
            assertEquals(listOf("s1", "s1", "s1", "s1", "s1"), listed.map { it.subscriptionId })

            store.setRead("f1", item("f1", 2).sortKey, false)
            store.setRead("f1", item("f1", 4).sortKey, true)
            listed = store.items(ItemQuery(RssItemScope.All, ordering = RssOrderingMode.OLDEST_FIRST))
            assertEquals(listOf(true, false, true, true, true), listed.map { it.isRead })
            assertEquals(mapOf("s1" to 1), store.unreadCounts())
            assertEquals(
                listOf(item("f1", 2).sortKey),
                store.items(ItemQuery(RssItemScope.All, filter = RssItemFilter.UNREAD)).map { it.sortKey },
            )
        }

    @Test
    fun `a server explicit unread survives the local watermark until re-listed without the marker`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1", watermark = "2026-01-09"))
            store.upsertItems(listOf(item("f1", 1, isRead = false, isReadExplicit = true)))

            val explicit = store.item("f1", item("f1", 1).sortKey)!!
            assertFalse(explicit.isRead)
            assertTrue(explicit.isReadExplicit)

            store.upsertItems(listOf(item("f1", 1)))
            assertTrue(store.item("f1", item("f1", 1).sortKey)!!.isRead)
        }

    @Test
    fun `a server upsert keeps local state while a change is pending`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1"))
            store.upsertItems(listOf(item("f1", 1), item("f1", 2)))
            store.setFavorite("f1", item("f1", 1).sortKey, true)
            store.setRead("f1", item("f1", 1).sortKey, true)

            store.upsertItems(listOf(item("f1", 1, title = "Retitled"), item("f1", 2, isRead = true)))

            val shielded = store.item("f1", item("f1", 1).sortKey)!!
            assertEquals("Retitled", shielded.title)
            assertTrue(shielded.isRead)
            assertTrue(shielded.isFavorite)
            assertTrue(shielded.isReadExplicit)
            assertTrue(store.item("f1", item("f1", 2).sortKey)!!.isRead, "no pending row: the server state wins")
            assertEquals(listOf(PendingKind.FAVORITE, PendingKind.READ), store.pendingMutations().map { it.kind })

            store.deletePending(store.pendingMutations().map { it.id })
            store.upsertItems(listOf(item("f1", 1)))
            assertFalse(store.item("f1", item("f1", 1).sortKey)!!.isFavorite)
        }

    @Test
    fun `total counts are the cached items per subscription, read or not`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1", watermark = "2026-01-03T23:59:59+00:00"))
            store.upsertSubscription(sub("s2", "f2"))
            store.upsertSubscription(sub("s3", "f3"))
            store.upsertItems((1..5).map { item("f1", it) } + listOf(item("f2", 1, isRead = true)))

            // Three of f1's five are read by the watermark; the total does not care.
            assertEquals(mapOf("s1" to 2), store.unreadCounts())
            assertEquals(mapOf("s1" to 5, "s2" to 1), store.totalCounts())

            store.markAllRead("s1")
            assertEquals(emptyMap<String, Int>(), store.unreadCounts())
            assertEquals(mapOf("s1" to 5, "s2" to 1), store.totalCounts(), "reading changes no total")
            assertNull(store.totalCounts()["s3"], "a feed with nothing cached is absent, not zero")
        }

    @Test
    fun `mark all read flips explicit unread items and queues a fence`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1"))
            store.upsertItems(listOf(item("f1", 1), item("f1", 2)))
            store.setRead("f1", item("f1", 1).sortKey, false)

            store.markAllRead("s1", watermark = "2026-12-31T00:00:00Z")

            assertEquals(emptyMap<String, Int>(), store.unreadCounts())
            assertTrue(store.item("f1", item("f1", 1).sortKey)!!.isRead)
            assertEquals("2026-12-31T00:00:00Z", store.subscription("s1")?.readWatermark)
            val queue = store.pendingMutations()
            assertEquals(listOf(PendingKind.READ, PendingKind.MARK_ALL_READ), queue.map { it.kind })
            assertEquals("s1", queue.last().subscriptionId)
            assertEquals("f1", queue.last().feedId)
            assertTrue(store.hasPending("f1", item("f1", 1).sortKey))
            assertEquals(2, store.pendingCount())
        }

    @Test
    fun `folder scope includes descendants and the day-grouped ordering holds`() =
        runTest {
            val store = InMemoryRssStore()
            store.replaceCatalog(
                RssCatalog(
                    folders =
                        listOf(
                            RssFolder("top", name = "Top"),
                            RssFolder("kid", parentFolderId = "top", name = "Kid"),
                        ),
                    subscriptions =
                        listOf(
                            sub("s1", "f1", folderId = "kid"),
                            sub("s2", "f2", folderId = "top"),
                            sub("s3", "f3"),
                        ),
                ),
            )
            store.upsertItems(listOf(item("f1", 1), item("f2", 2), item("f3", 3)))

            assertEquals(listOf("f2", "f1"), store.items(ItemQuery(RssItemScope.Folder("top"))).map { it.feedId })
            assertEquals(listOf("f1"), store.items(ItemQuery(RssItemScope.Folder("kid"))).map { it.feedId })
            assertEquals(3, store.items(ItemQuery(RssItemScope.All)).size)
            assertEquals(emptyList<RssItem>(), store.items(ItemQuery(RssItemScope.Subscription("nope"))))

            store.upsertItems(
                listOf(
                    item("f3", 4, day = "2026-01-09").copy(sortKey = "2026-01-09T08:00:00+00:00#a", itemId = "a"),
                    item("f3", 5, day = "2026-01-09").copy(sortKey = "2026-01-09T09:00:00+00:00#b", itemId = "b"),
                ),
            )
            val grouped =
                store.items(
                    ItemQuery(RssItemScope.Subscription("s3"), ordering = RssOrderingMode.NEWEST_DAY_OLDEST_WITHIN),
                )
            assertEquals(listOf("a", "b", "i3"), grouped.map { it.itemId })
        }

    @Test
    fun `full-text search is per feed, prefix-matched, and ANDs its tokens`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1"))
            store.upsertSubscription(sub("s2", "f2"))
            store.upsertItems(
                listOf(
                    item("f1", 1, title = "Swift actors", body = "<p>Isolation &amp; concurrency</p>"),
                    item("f1", 2, title = "Kotlin", body = "<p>Isolating a recipe</p>"),
                    item("f2", 3, title = "Swift birds", body = "<p>Migration</p>"),
                ),
            )

            assertEquals(listOf("i1"), store.search("f1", "swift").map { it.itemId })
            assertEquals(setOf("i1", "i2"), store.search("f1", "isolat").map { it.itemId }.toSet())
            assertEquals(emptyList<RssItem>(), store.search("f1", "actor recipe"))
            assertEquals(emptyList<RssItem>(), store.search("f1", "\"  "))
            assertEquals("hello* not* world*", RssRules.ftsQuery("hello NOT world"))
            assertNull(RssRules.ftsQuery("\" - "))
        }

    @Test
    fun `sync state round-trips and defaults for an unknown feed`() =
        runTest {
            val store = InMemoryRssStore()
            assertEquals(FeedSyncState(), store.syncState("f9"))
            val state = FeedSyncState("since", "older", true, "2026-01-01T00:00:00Z", "state")
            store.setSyncState("f1", state)
            assertEquals(state, store.syncState("f1"))
        }

    @Test
    fun `server states apply per flag around the pending queue and skip uncached items`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(sub("s1", "f1"))
            store.upsertItems(listOf(item("f1", 1), item("f1", 2)))
            store.setRead("f1", item("f1", 1).sortKey, true)

            store.applyServerStates(
                listOf(
                    RssItemState("f1", item("f1", 1).sortKey, isRead = false, isReadExplicit = true, isFavorite = true),
                    RssItemState("f1", item("f1", 2).sortKey, isRead = true, isReadExplicit = true),
                    RssItemState("f1", "missing", isRead = true),
                ),
            )

            val one = store.item("f1", item("f1", 1).sortKey)!!
            assertTrue(one.isRead, "a queued local read wins over the server's copy")
            assertTrue(one.isFavorite, "the favorite flag has no queued change and applies")
            assertTrue(store.item("f1", item("f1", 2).sortKey)!!.isRead)
            assertEquals(2, store.itemCount("f1"))
        }
}
