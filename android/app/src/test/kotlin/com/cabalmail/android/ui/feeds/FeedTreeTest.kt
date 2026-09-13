package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssSubscription
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The feed tree's ordering, nesting, collapse, filter, and unread roll-up rules (the Apple `FeedSidebarRows`). */
class FeedTreeTest {
    private val folders =
        listOf(
            RssFolder("news", name = "News", displayOrder = 1),
            RssFolder("tech", parentFolderId = "news", name = "Tech"),
            RssFolder("art", name = "Art", displayOrder = 0),
        )
    private val subs =
        listOf(
            RssSubscription("s-root", "f1", feed = RssFeedSummary("f1", title = "Zed root")),
            RssSubscription("s-news", "f2", folderId = "news", feed = RssFeedSummary("f2", title = "Daily")),
            RssSubscription("s-tech", "f3", folderId = "tech", feed = RssFeedSummary("f3", title = "bits")),
            RssSubscription("s-art", "f4", folderId = "art", customTitle = "Paint"),
        )
    private val counts = mapOf("s-root" to 1, "s-news" to 2, "s-tech" to 4, "s-art" to 8)

    @Test
    fun `folders by display order then name, child folders before feeds, root feeds last`() {
        val rows = FeedTree.rows(folders, subs, counts)
        assertEquals(
            listOf("folder:art", "sub:s-art", "folder:news", "folder:tech", "sub:s-tech", "sub:s-news", "sub:s-root"),
            rows.map { it.id },
        )
        assertEquals(listOf(0, 1, 0, 1, 2, 1, 0), rows.map { it.depth })
        assertEquals(6, rows.first { it.id == "folder:news" }.unread, "a folder rolls up its children's feeds")
        assertEquals(4, rows.first { it.id == "folder:tech" }.unread)
        assertTrue(rows.first { it.id == "folder:news" }.hasChildren)
        assertEquals(15, FeedTree.totalUnread(counts))
    }

    @Test
    fun `a collapsed folder hides its contents but keeps its roll-up`() {
        val rows = FeedTree.rows(folders, subs, counts, collapsed = setOf("news"))
        assertEquals(listOf("folder:art", "sub:s-art", "folder:news", "sub:s-root"), rows.map { it.id })
        assertEquals(6, rows.first { it.id == "folder:news" }.unread)
    }

    @Test
    fun `a filter matches feed titles, shows only folders with a match, and ignores collapse`() {
        val rows = FeedTree.rows(folders, subs, counts, collapsed = setOf("news"), filter = "  BIT ")
        assertEquals(listOf("folder:news", "folder:tech", "sub:s-tech"), rows.map { it.id })
        assertFalse(rows.any { it.id == "folder:art" })
        assertEquals(6, rows.first { it.id == "folder:news" }.unread, "the roll-up is over the unfiltered tree")
    }

    @Test
    fun `feed rows carry their subscription and a zero count when absent`() {
        val rows = FeedTree.rows(folders, subs, emptyMap())
        val root = rows.first { it.id == "sub:s-root" }
        assertEquals("s-root", root.subscription?.subscriptionId)
        assertEquals(0, root.unread)
        assertEquals("Paint", rows.first { it.id == "sub:s-art" }.title)
    }
}
