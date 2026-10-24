package com.cabalmail.android.navigation

import com.cabalmail.kit.models.NavState
import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.rss.InMemoryRssStore
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What the cross-device prompt names (#1931): the offer used to read
 * "Pick up where you left off?" for every cursor, so Resume could land in
 * a feed the reader had never opened with nothing beforehand to say so.
 */
class ResumeDestinationTest {
    private fun feedCursor(itemId: String) = NavState(kind = NavState.KIND_RSS, rssItem = itemId)

    private fun item(
        feedId: String = "feed-1",
        sortKey: String = "0001",
        subscriptionId: String = "",
        title: String = "",
    ) = RssItem(feedId = feedId, sortKey = sortKey, subscriptionId = subscriptionId, title = title)

    /**
     * The shape stage actually serves: `custom_title` empty, the real
     * title in the nested feed summary. A fixture that sets `customTitle`
     * instead passes without ever reaching [RssSubscription.displayTitle]'s
     * feed-summary branch, which is the branch every real install takes.
     */
    private fun subscription(
        subscriptionId: String = "sub-7",
        feedId: String = "feed-1",
        feedTitle: String = "AWS News Blog",
        customTitle: String = "",
    ) = RssSubscription(
        subscriptionId = subscriptionId,
        feedId = feedId,
        customTitle = customTitle,
        feed = RssFeedSummary(feedId = feedId, title = feedTitle),
    )

    /** A device that cannot reach the server, or an item the server lost. */
    private val fetchesNothing: suspend (String, String) -> RssItem? = { _, _ -> null }

    /** A catalogue request that answers nothing: offline, or the feed is gone. */
    private val fetchesNoSubscription: suspend (String) -> RssSubscription? = { null }

    @Test
    fun `a mail cursor names its folder`() =
        runTest {
            val name =
                ResumeDestination.name(
                    NavState(folder = "Projects.Alpha"),
                    InMemoryRssStore(),
                    fetchesNothing,
                )
            assertEquals("Projects.Alpha", name)
        }

    @Test
    fun `a mail cursor with no folder names nothing`() =
        runTest {
            assertNull(ResumeDestination.name(NavState(folder = " "), InMemoryRssStore(), fetchesNothing))
        }

    @Test
    fun `a feed cursor names the feed the item belongs to`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(subscription())
            store.upsertItems(listOf(item(subscriptionId = "sub-7", title = "A post")))

            val name = ResumeDestination.name(feedCursor("feed-1#0001"), store, fetchesNothing, fetchesNoSubscription)

            assertEquals("AWS News Blog", name)
        }

    @Test
    fun `an item from a feed neither this install nor the server knows falls back to its title`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertItems(listOf(item(subscriptionId = "sub-gone", title = "A post")))

            val name = ResumeDestination.name(feedCursor("feed-1#0001"), store, fetchesNothing, fetchesNoSubscription)

            assertEquals("A post", name)
        }

    /**
     * The launch #2109 reports: the Feeds tab has never run on this
     * install, so there is no local catalogue to look the feed up in —
     * `rss_cache.db` does not even exist until the first query creates it.
     * The item arrives over the network naming its subscription, and
     * before the fix the name died on the store lookup that followed.
     */
    @Test
    fun `a cold launch with no local catalogue names the feed from the server`() =
        runTest {
            val store = InMemoryRssStore()
            var catalogueFetches = 0

            val name =
                ResumeDestination.name(
                    cursor = feedCursor("feed-1#0001"),
                    store = store,
                    fetchItem = { feedId, sortKey ->
                        item(feedId = feedId, sortKey = sortKey, subscriptionId = "sub-7", title = "A post")
                    },
                    fetchSubscription = { feedId ->
                        catalogueFetches++
                        subscription().takeIf { it.feedId == feedId }
                    },
                )

            assertEquals("AWS News Blog", name)
            assertEquals(1, catalogueFetches)
        }

    /**
     * The same gap reached from the other side: the item is local, but the
     * subscriptions table has no row for its feed, so the id the store
     * derives for it is empty. The feed is still nameable.
     */
    @Test
    fun `a local item whose feed is not in the local catalogue is named from the server`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertItems(listOf(item(subscriptionId = "", title = "A post")))

            val name =
                ResumeDestination.name(
                    cursor = feedCursor("feed-1#0001"),
                    store = store,
                    fetchItem = fetchesNothing,
                    fetchSubscription = { feedId -> subscription().takeIf { it.feedId == feedId } },
                )

            assertEquals("AWS News Blog", name)
        }

    /** The local catalogue answers, so the launch costs no catalogue request. */
    @Test
    fun `a feed the install already knows is named without asking the server`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(subscription())
            store.upsertItems(listOf(item(subscriptionId = "sub-7", title = "A post")))
            var catalogueFetches = 0

            val name =
                ResumeDestination.name(
                    cursor = feedCursor("feed-1#0001"),
                    store = store,
                    fetchItem = fetchesNothing,
                    fetchSubscription = {
                        catalogueFetches++
                        subscription()
                    },
                )

            assertEquals("AWS News Blog", name)
            assertEquals(0, catalogueFetches)
        }

    /**
     * An item this device has not synced is fetched, named, and kept, so
     * the tap that follows opens it from the store.
     */
    @Test
    fun `an unsynced item is fetched and cached`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(subscription(customTitle = "Renamed by me"))
            var fetches = 0

            val name =
                ResumeDestination.name(
                    cursor = feedCursor("feed-1#0001"),
                    store = store,
                    fetchItem = { feedId, sortKey ->
                        fetches++
                        item(feedId = feedId, sortKey = sortKey, subscriptionId = "sub-7", title = "A post")
                    },
                    fetchSubscription = fetchesNoSubscription,
                )

            assertEquals("Renamed by me", name, "a custom title still wins over the feed's own")
            assertEquals(1, fetches)
            assertTrue(store.item("feed-1", "0001") != null, "the fetched item is kept for the tap")
        }

    @Test
    fun `a feed cursor whose item cannot be resolved names nothing`() =
        runTest {
            val name =
                ResumeDestination.name(
                    feedCursor("feed-1#0001"),
                    InMemoryRssStore(),
                    fetchesNothing,
                    fetchesNoSubscription,
                )
            assertNull(name)
        }

    @Test
    fun `a feed cursor with no item names nothing`() =
        runTest {
            val cursor = NavState(kind = NavState.KIND_RSS, folder = "INBOX")
            // Not a feed cursor without an item, so the mail branch answers.
            assertEquals("INBOX", ResumeDestination.name(cursor, InMemoryRssStore(), fetchesNothing))
        }
}
