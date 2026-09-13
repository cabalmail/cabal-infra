package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription

/** One row of the feed list: a folder or a feed, at its depth in the tree. */
data class FeedTreeRow(
    val id: String,
    val scope: RssItemScope,
    val title: String,
    val depth: Int,
    val isFolder: Boolean,
    val hasChildren: Boolean,
    val unread: Int,
    /** The subscription behind a feed row (its health rides on `feed`); null for folders. */
    val subscription: RssSubscription? = null,
)

/**
 * The feed list's rows, built the way the Apple sidebar builds them
 * (`FeedSidebarRows`): folders grouped by parent, siblings by display
 * order then name; within a folder its child folders first, then its
 * feeds by title; root-level feeds after the whole folder tree. A
 * collapsed folder hides its contents unless a filter is active, when the
 * tree auto-expands; a folder is shown only if a feed under it matches.
 * Unread counts roll up over the unfiltered tree. Pure, so it unit-tests
 * without Compose.
 */
object FeedTree {
    fun rows(
        folders: List<RssFolder>,
        subscriptions: List<RssSubscription>,
        unreadCounts: Map<String, Int>,
        collapsed: Set<String> = emptySet(),
        filter: String = "",
    ): List<FeedTreeRow> {
        val needle = filter.trim().lowercase()
        val foldersByParent = folders.groupBy { it.parentFolderId }
        val subsByFolder = subscriptions.groupBy { it.folderId }

        fun childFolders(parent: String) =
            foldersByParent[parent].orEmpty().sortedWith(compareBy({ it.displayOrder }, { it.name.lowercase() }))

        fun feedsIn(folderId: String) =
            subsByFolder[folderId]
                .orEmpty()
                .filter { needle.isEmpty() || it.displayTitle.lowercase().contains(needle) }
                .sortedBy { it.displayTitle.lowercase() }

        fun hasMatch(folderId: String): Boolean =
            feedsIn(folderId).isNotEmpty() || childFolders(folderId).any { hasMatch(it.folderId) }

        fun unreadUnder(folderId: String): Int =
            subsByFolder[folderId].orEmpty().sumOf { unreadCounts[it.subscriptionId] ?: 0 } +
                childFolders(folderId).sumOf { unreadUnder(it.folderId) }

        val rows = ArrayList<FeedTreeRow>()

        fun feedRow(
            sub: RssSubscription,
            depth: Int,
        ) = FeedTreeRow(
            id = "sub:${sub.subscriptionId}",
            scope = RssItemScope.Subscription(sub.subscriptionId),
            title = sub.displayTitle,
            depth = depth,
            isFolder = false,
            hasChildren = false,
            unread = unreadCounts[sub.subscriptionId] ?: 0,
            subscription = sub,
        )

        fun visit(
            parent: String,
            depth: Int,
        ) {
            for (folder in childFolders(parent)) {
                if (needle.isNotEmpty() && !hasMatch(folder.folderId)) continue
                val children = childFolders(folder.folderId)
                val feeds = feedsIn(folder.folderId)
                rows +=
                    FeedTreeRow(
                        id = "folder:${folder.folderId}",
                        scope = RssItemScope.Folder(folder.folderId),
                        title = folder.name,
                        depth = depth,
                        isFolder = true,
                        hasChildren = children.isNotEmpty() || feeds.isNotEmpty(),
                        unread = unreadUnder(folder.folderId),
                    )
                if (folder.folderId in collapsed && needle.isEmpty()) continue
                visit(folder.folderId, depth + 1)
                feeds.forEach { rows += feedRow(it, depth + 1) }
            }
        }
        visit("", 0)
        feedsIn("").forEach { rows += feedRow(it, 0) }
        return rows
    }

    /** The All Feeds badge: every subscription's unread count summed. */
    fun totalUnread(unreadCounts: Map<String, Int>): Int = unreadCounts.values.sum()
}
