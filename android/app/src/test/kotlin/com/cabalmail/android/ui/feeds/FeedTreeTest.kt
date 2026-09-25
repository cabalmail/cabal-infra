package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItemScope
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
    fun `totals roll up like unread, never filter, and default to zero`() {
        val totals = mapOf("s-root" to 10, "s-news" to 20, "s-tech" to 40, "s-art" to 80)
        val rows = FeedTree.rows(folders, subs, counts, totalCounts = totals)
        assertEquals(60, rows.first { it.id == "folder:news" }.total, "a folder rolls up its subtree's items")
        assertEquals(40, rows.first { it.id == "folder:tech" }.total)
        assertEquals(80, rows.first { it.id == "sub:s-art" }.total)
        assertEquals(6, rows.first { it.id == "folder:news" }.unread, "unread is untouched by totals")
        assertEquals(150, FeedTree.totalItems(totals))
        // A read feed with cached items still hides under the Unread pill:
        // the total is a badge, not a filter.
        val unreadRows = FeedTree.rows(folders, subs, mapOf("s-tech" to 4), unreadOnly = true, totalCounts = totals)
        assertEquals(listOf("folder:news", "folder:tech", "sub:s-tech"), unreadRows.map { it.id })
        assertEquals(60, unreadRows.first { it.id == "folder:news" }.total, "the roll-up is over the unfiltered tree")
        assertEquals(0, FeedTree.rows(folders, subs, counts).first { it.id == "sub:s-art" }.total)
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

    @Test
    fun `unread only hides read feeds and folders with a zero roll-up, subtree included`() {
        val counts = mapOf("s-tech" to 4)
        val rows = FeedTree.rows(folders, subs, counts, unreadOnly = true)
        assertEquals(listOf("folder:news", "folder:tech", "sub:s-tech"), rows.map { it.id })
    }

    @Test
    fun `unread only with nothing unread leaves only the All Feeds item, which the screen adds`() {
        assertEquals(emptyList<String>(), FeedTree.rows(folders, subs, emptyMap(), unreadOnly = true).map { it.id })
    }

    @Test
    fun `unread only and the text filter combine`() {
        val rows = FeedTree.rows(folders, subs, counts, filter = "d", unreadOnly = true)
        // "Daily" and "Zed root" match the text; both have unread. "bits" does not match.
        assertEquals(listOf("folder:news", "sub:s-news", "sub:s-root"), rows.map { it.id })
        assertEquals(
            listOf("folder:news", "sub:s-news"),
            FeedTree.rows(folders, subs, mapOf("s-news" to 1), filter = "d", unreadOnly = true).map { it.id },
        )
    }

    @Test
    fun `the kept feed stays with its ancestors when it has no unread`() {
        val counts = mapOf("s-art" to 8)
        val rows = FeedTree.rows(folders, subs, counts, unreadOnly = true, keep = RssItemScope.Subscription("s-tech"))
        assertEquals(listOf("folder:art", "sub:s-art", "folder:news", "folder:tech", "sub:s-tech"), rows.map { it.id })
        assertEquals(0, rows.first { it.id == "sub:s-tech" }.unread)
    }

    @Test
    fun `the kept folder stays when its roll-up is zero`() {
        val rows = FeedTree.rows(folders, subs, emptyMap(), unreadOnly = true, keep = RssItemScope.Folder("tech"))
        assertEquals(listOf("folder:news", "folder:tech"), rows.map { it.id })
    }

    @Test
    fun `keeping All Feeds pins nothing in the tree`() {
        assertEquals(
            emptyList<String>(),
            FeedTree.rows(folders, subs, emptyMap(), unreadOnly = true, keep = RssItemScope.All).map { it.id },
        )
    }

    @Test
    fun `keep changes nothing without a filter`() {
        assertEquals(
            FeedTree.rows(folders, subs, counts).map { it.id },
            FeedTree.rows(folders, subs, counts, keep = RssItemScope.Subscription("s-tech")).map { it.id },
        )
    }

    @Test
    fun `collapsible folders are those with a child folder or a feed`() {
        assertEquals(setOf("news", "tech", "art"), FeedTree.collapsibleFolderIds(folders, subs))
        val empty = folders + RssFolder("void", name = "Void")
        assertEquals(setOf("news", "tech", "art"), FeedTree.collapsibleFolderIds(empty, subs))
        assertEquals(setOf("news"), FeedTree.collapsibleFolderIds(folders, emptyList()))
        assertEquals(emptySet<String>(), FeedTree.collapsibleFolderIds(emptyList(), subs))
    }
}
