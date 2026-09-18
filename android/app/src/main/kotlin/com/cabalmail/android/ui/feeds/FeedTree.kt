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
 * With [rows]' `unreadOnly`, a feed is shown only with unread items and a
 * folder only with a positive roll-up (a folder with none hides its whole
 * subtree); the text filter and the unread filter combine. The row whose
 * scope is `keep` — the open one — is always shown, with its ancestors, so
 * the selection never disappears from under the reader. Unread counts roll
 * up over the unfiltered tree. Pure, so it unit-tests without Compose.
 */
object FeedTree {
    fun rows(
        folders: List<RssFolder>,
        subscriptions: List<RssSubscription>,
        unreadCounts: Map<String, Int>,
        collapsed: Set<String> = emptySet(),
        filter: String = "",
        unreadOnly: Boolean = false,
        keep: RssItemScope? = null,
    ): List<FeedTreeRow> {
        val needle = filter.trim().lowercase()
        val foldersByParent = folders.groupBy { it.parentFolderId }
        val subsByFolder = subscriptions.groupBy { it.folderId }
        val keptFolder = (keep as? RssItemScope.Folder)?.folderId
        val keptSubscription = (keep as? RssItemScope.Subscription)?.subscriptionId

        fun childFolders(parent: String) =
            foldersByParent[parent].orEmpty().sortedWith(compareBy({ it.displayOrder }, { it.name.lowercase() }))

        fun unreadUnder(folderId: String): Int =
            subsByFolder[folderId].orEmpty().sumOf { unreadCounts[it.subscriptionId] ?: 0 } +
                childFolders(folderId).sumOf { unreadUnder(it.folderId) }

        fun feedsIn(folderId: String) =
            subsByFolder[folderId]
                .orEmpty()
                .filter { needle.isEmpty() || it.displayTitle.lowercase().contains(needle) }
                .filter {
                    !unreadOnly || (unreadCounts[it.subscriptionId] ?: 0) > 0 || it.subscriptionId == keptSubscription
                }.sortedBy { it.displayTitle.lowercase() }

        /** Whether the kept scope lives at or under this folder, which pins the folder's whole ancestry. */
        fun holdsKept(folderId: String): Boolean =
            folderId == keptFolder ||
                (
                    keptSubscription != null &&
                        subsByFolder[folderId].orEmpty().any { it.subscriptionId == keptSubscription }
                ) ||
                childFolders(folderId).any { holdsKept(it.folderId) }

        fun hasMatch(folderId: String): Boolean =
            feedsIn(folderId).isNotEmpty() || childFolders(folderId).any { hasMatch(it.folderId) }

        fun shown(folderId: String): Boolean =
            holdsKept(folderId) ||
                (
                    (needle.isEmpty() || hasMatch(folderId)) &&
                        (!unreadOnly || unreadUnder(folderId) > 0)
                )

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
                if (!shown(folder.folderId)) continue
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

    /**
     * The folders "collapse all" folds: those with a child folder or a feed
     * inside. An empty folder has nothing to hide, so it is left alone and
     * the expand/collapse-all buttons disable when this is empty.
     */
    fun collapsibleFolderIds(
        folders: List<RssFolder>,
        subscriptions: List<RssSubscription>,
    ): Set<String> {
        val parents = folders.map { it.parentFolderId }.toSet() + subscriptions.map { it.folderId }.toSet()
        return folders.map { it.folderId }.filter { it in parents }.toSet()
    }
}
