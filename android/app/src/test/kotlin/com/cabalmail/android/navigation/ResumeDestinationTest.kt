package com.cabalmail.android.navigation

import com.cabalmail.kit.models.NavState
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

    /** A device that cannot reach the server, or an item the server lost. */
    private val fetchesNothing: suspend (String, String) -> RssItem? = { _, _ -> null }

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
            store.upsertSubscription(
                RssSubscription(subscriptionId = "sub-7", feedId = "feed-1", customTitle = "AWS News Blog"),
            )
            store.upsertItems(listOf(item(subscriptionId = "sub-7", title = "A post")))

            val name = ResumeDestination.name(feedCursor("feed-1#0001"), store, fetchesNothing)

            assertEquals("AWS News Blog", name)
        }

    @Test
    fun `an item from a feed this install does not know falls back to its title`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertItems(listOf(item(subscriptionId = "sub-gone", title = "A post")))

            val name = ResumeDestination.name(feedCursor("feed-1#0001"), store, fetchesNothing)

            assertEquals("A post", name)
        }

    /**
     * An item this device has not synced is fetched, named, and kept, so
     * the tap that follows opens it from the store.
     */
    @Test
    fun `an unsynced item is fetched and cached`() =
        runTest {
            val store = InMemoryRssStore()
            store.upsertSubscription(
                RssSubscription(subscriptionId = "sub-7", feedId = "feed-1", customTitle = "AWS News Blog"),
            )
            var fetches = 0

            val name =
                ResumeDestination.name(feedCursor("feed-1#0001"), store) { feedId, sortKey ->
                    fetches++
                    item(feedId = feedId, sortKey = sortKey, subscriptionId = "sub-7", title = "A post")
                }

            assertEquals("AWS News Blog", name)
            assertEquals(1, fetches)
            assertTrue(store.item("feed-1", "0001") != null, "the fetched item is kept for the tap")
        }

    @Test
    fun `a feed cursor whose item cannot be resolved names nothing`() =
        runTest {
            val name = ResumeDestination.name(feedCursor("feed-1#0001"), InMemoryRssStore(), fetchesNothing)
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
