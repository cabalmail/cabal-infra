package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription

/** One row of the feed list title's scope-switch menu. */
data class FeedScopeMenuRow(
    val scope: RssItemScope,
    val title: String,
    /** Nesting depth for indentation: All Feeds and root rows at 0. */
    val depth: Int,
    val isFolder: Boolean,
)

/**
 * The scope-switch menu behind the feed list's title, the feed sibling of
 * [com.cabalmail.android.ui.mail.FolderSections.switchMenu] (and of the
 * Apple `FeedScopeSwitchMenuPolicy`): All Feeds first, then the whole
 * folder tree flattened depth-first at its depth, each folder's contents
 * beneath it, with nothing collapsed or filtered — the menu is a map of
 * every scope, not a view of the tree's current fold. The order within
 * a folder is the tree's ([FeedTree.rows]: child folders, then feeds by
 * title; root feeds after the folders), so the menu reads in the same
 * order as the sidebar the user just left. Pure, so it unit-tests without
 * Compose; the composable marks the current scope.
 */
object FeedScopeSwitchMenu {
    fun rows(
        folders: List<RssFolder>,
        subscriptions: List<RssSubscription>,
        allFeedsTitle: String,
    ): List<FeedScopeMenuRow> =
        listOf(FeedScopeMenuRow(scope = RssItemScope.All, title = allFeedsTitle, depth = 0, isFolder = false)) +
            FeedTree.rows(folders, subscriptions, unreadCounts = emptyMap()).map { row ->
                FeedScopeMenuRow(scope = row.scope, title = row.title, depth = row.depth, isFolder = row.isFolder)
            }
}
