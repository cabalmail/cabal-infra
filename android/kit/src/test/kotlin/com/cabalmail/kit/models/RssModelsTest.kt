package com.cabalmail.kit.models

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The RSS wire models: lenient decoding, the scope token, and the local `applying` helpers. */
class RssModelsTest {
    @Test
    fun `unknown enum values and missing fields decode to the defaults`() {
        val sub =
            RssWire.json.decodeFromString<RssSubscription>(
                """{"subscription_id":"s1","feed_id":"f1","ordering_mode":"spiral","default_filter":"flagged",
                   "some_future_field":1}""",
            )
        assertEquals(RssOrderingMode.NEWEST_FIRST, sub.orderingMode)
        assertEquals(RssItemFilter.UNREAD, sub.defaultFilter)
        assertEquals(RssRemoteContentMode.INHERIT, sub.defaultRemoteContent)
        assertEquals("", sub.folderId)
        assertNull(sub.feed)
        assertEquals("f1", sub.displayTitle)

        val withFeed = sub.copy(feed = RssFeedSummary(feedId = "f1", title = "Feed title"))
        assertEquals("Feed title", withFeed.displayTitle)
        assertEquals("Mine", withFeed.copy(customTitle = "Mine").displayTitle)
    }

    @Test
    fun `item identity is feed and sort key and the body prefers content`() {
        val item = RssItem(feedId = "f1", sortKey = "2026-01-01T00:00:00+00:00#i1", summaryHtml = "<p>s</p>")
        assertEquals("f1#2026-01-01T00:00:00+00:00#i1", item.id)
        assertEquals("<p>s</p>", item.bodyHtml)
        assertEquals("<p>c</p>", item.copy(contentHtml = "<p>c</p>").bodyHtml)
    }

    @Test
    fun `scope tokens round-trip and reject junk`() {
        assertEquals("all", RssItemScope.All.token)
        assertEquals("sub:s1", RssItemScope.Subscription("s1").token)
        assertEquals("folder:f:1", RssItemScope.Folder("f:1").token)
        assertEquals(RssItemScope.All, RssItemScope.fromToken("all"))
        assertEquals(RssItemScope.Subscription("s1"), RssItemScope.fromToken("sub:s1"))
        assertEquals(RssItemScope.Folder("f:1"), RssItemScope.fromToken("folder:f:1"))
        assertNull(RssItemScope.fromToken("sub:"))
        assertNull(RssItemScope.fromToken("mailbox:INBOX"))
        assertNull(RssItemScope.fromToken(""))
    }

    @Test
    fun `applying an update changes only the named fields`() {
        val sub = RssSubscription(subscriptionId = "s1", feedId = "f1", customTitle = "Old", folderId = "d1")
        val updated =
            sub.applying(
                RssSubscriptionUpdate(folderId = "", defaultRemoteContent = RssRemoteContentMode.HIDE),
            )
        assertEquals("Old", updated.customTitle)
        assertEquals("", updated.folderId)
        assertEquals(RssRemoteContentMode.HIDE, updated.defaultRemoteContent)
        assertTrue(RssSubscriptionUpdate().isEmpty)
        // An explicit `inherit` is still a change.
        assertFalse(RssSubscriptionUpdate(defaultRemoteContent = RssRemoteContentMode.INHERIT).isEmpty)

        val folder = RssFolder(folderId = "d1", name = "News")
        assertEquals(
            RssItemFilter.FAVORITE,
            folder.applying(RssFolderUpdate(defaultFilter = RssItemFilter.FAVORITE)).defaultFilter,
        )
        assertEquals("News", folder.applying(RssFolderUpdate(defaultFilter = RssItemFilter.FAVORITE)).name)
        assertTrue(RssFolderUpdate().isEmpty)
        assertFalse(RssFolderUpdate(defaultFilter = RssItemFilter.ALL).isEmpty)
    }

    @Test
    fun `page shapes decode with their cursors and has_more flags`() {
        val listing = RssWire.json.decodeFromString<RssItemsPage>("""{"items":[],"next_cursor":null}""")
        assertNull(listing.nextCursor)
        val sync = RssWire.json.decodeFromString<RssSyncPage>("""{"items":[],"next_since":"c1","has_more":true}""")
        assertEquals("c1", sync.nextSince)
        assertTrue(sync.hasMore)
        val states =
            RssWire.json.decodeFromString<RssStateSyncPage>(
                """{"states":[{"feed_id":"f1","sort_key":"k","is_read":true,"is_read_explicit":true}],
                   "next_state_since":"x","has_more":false}""",
            )
        assertEquals("x", states.nextSince)
        assertTrue(states.states.single().isReadExplicit)
    }
}
