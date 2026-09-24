package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The feed list title's scope menu (the sibling of `FolderSectionsTest`'s switch-menu cases). */
class FeedScopeSwitchMenuTest {
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

    @Test
    fun `All Feeds leads, then the tree depth-first with each folder's contents beneath it`() {
        val rows = FeedScopeSwitchMenu.rows(folders, subs, allFeedsTitle = "All Feeds")
        assertEquals(
            listOf(
                RssItemScope.All,
                RssItemScope.Folder("art"),
                RssItemScope.Subscription("s-art"),
                RssItemScope.Folder("news"),
                RssItemScope.Folder("tech"),
                RssItemScope.Subscription("s-tech"),
                RssItemScope.Subscription("s-news"),
                RssItemScope.Subscription("s-root"),
            ),
            rows.map { it.scope },
        )
        assertEquals(listOf(0, 0, 1, 0, 1, 2, 1, 0), rows.map { it.depth })
        assertEquals(
            listOf("All Feeds", "Art", "Paint", "News", "Tech", "bits", "Daily", "Zed root"),
            rows.map { it.title },
        )
    }

    @Test
    fun `folders and feeds are told apart and All Feeds is neither`() {
        val rows = FeedScopeSwitchMenu.rows(folders, subs, allFeedsTitle = "All Feeds")
        assertEquals(listOf(false, true, false, true, true, false, false, false), rows.map { it.isFolder })
        assertFalse(rows.first().isFolder)
    }

    @Test
    fun `the menu is the whole tree regardless of the sidebar's fold or filter`() {
        // FeedTree hides a collapsed folder's contents and read feeds under the
        // Unread pill; the menu never does, since it is how a reader reaches a
        // scope the tree is not currently showing.
        val menu = FeedScopeSwitchMenu.rows(folders, subs, allFeedsTitle = "All Feeds")
        val unfolded = FeedTree.rows(folders, subs, emptyMap())
        assertEquals(unfolded.map { it.scope }, menu.drop(1).map { it.scope })
        assertTrue(menu.any { it.scope == RssItemScope.Subscription("s-tech") })
    }

    @Test
    fun `an empty catalog offers only All Feeds`() {
        assertEquals(
            listOf(FeedScopeMenuRow(RssItemScope.All, "All Feeds", depth = 0, isFolder = false)),
            FeedScopeSwitchMenu.rows(emptyList(), emptyList(), allFeedsTitle = "All Feeds"),
        )
    }
}
