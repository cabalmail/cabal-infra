package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.settings.LoadRemoteContent

/**
 * Which pill a feed list opens on and what a tap writes back — the Apple
 * `FeedListFilterPolicy`. A feed's or feed folder's pill lives on its
 * server row (`default_filter`), the All Feeds list's on the synced
 * `filter:feeds:all` preference; a row that is not at hand reads as
 * Unread, never All. A tap on the pill the row already stores writes
 * nothing.
 */
object FeedListFilterPolicy {
    fun initial(
        scope: RssItemScope,
        subscription: RssSubscription?,
        folder: RssFolder?,
        allFeedsFilter: RssItemFilter,
    ): RssItemFilter =
        when (scope) {
            RssItemScope.All -> allFeedsFilter
            is RssItemScope.Subscription -> subscription?.defaultFilter ?: RssItemFilter.DEFAULT_FOR_FEEDS
            is RssItemScope.Folder -> folder?.defaultFilter ?: RssItemFilter.DEFAULT_FOR_FEEDS
        }

    fun stickyUpdate(
        subscription: RssSubscription,
        filter: RssItemFilter,
    ): RssSubscriptionUpdate? =
        if (subscription.defaultFilter == filter) null else RssSubscriptionUpdate(defaultFilter = filter)

    fun stickyUpdate(
        folder: RssFolder,
        filter: RssItemFilter,
    ): RssFolderUpdate? = if (folder.defaultFilter == filter) null else RssFolderUpdate(defaultFilter = filter)
}

/** How the reader first opens an item. */
data class FeedDetailInitial(
    val showsArticle: Boolean,
    val readerMode: Boolean,
    val remoteContentAllowed: Boolean,
)

/**
 * The reader's initial state from the feed's defaults, and what each of
 * its three toggles writes back — the Apple `FeedDetailPolicy`. Read at
 * view-model creation from the store row, never from a parent that may
 * not have resolved the subscription yet (the "settings have no effect"
 * round on Apple, 1.17.0). Remote content: `SHOW` and `HIDE` decide for
 * the feed; `INHERIT` follows the app preference, where only `ALWAYS`
 * reads as on — the feed reader has no per-item prompt, so `ASK` is off.
 */
object FeedDetailPolicy {
    fun initial(
        subscription: RssSubscription?,
        hasArticleUrl: Boolean,
        globalRemoteContent: LoadRemoteContent,
    ): FeedDetailInitial {
        val openMode = subscription?.defaultOpenMode ?: RssOpenMode.SUMMARY
        val styling = subscription?.defaultStyling ?: RssStyling.READER
        val remote =
            when (subscription?.defaultRemoteContent ?: RssRemoteContentMode.INHERIT) {
                RssRemoteContentMode.SHOW -> true
                RssRemoteContentMode.HIDE -> false
                RssRemoteContentMode.INHERIT -> globalRemoteContent == LoadRemoteContent.ALWAYS
            }
        return FeedDetailInitial(
            showsArticle = openMode == RssOpenMode.ARTICLE && hasArticleUrl,
            readerMode = styling == RssStyling.READER,
            remoteContentAllowed = remote,
        )
    }

    /** The article toggle writes `default_open_mode`; nothing without an article link. */
    fun articleUpdate(
        subscription: RssSubscription,
        showingArticle: Boolean,
        hasArticleUrl: Boolean,
    ): RssSubscriptionUpdate? {
        if (!hasArticleUrl) return null
        val mode = if (showingArticle) RssOpenMode.ARTICLE else RssOpenMode.SUMMARY
        return if (subscription.defaultOpenMode == mode) null else RssSubscriptionUpdate(defaultOpenMode = mode)
    }

    /** The styling toggle writes `default_styling`. */
    fun stylingUpdate(
        subscription: RssSubscription,
        readerMode: Boolean,
    ): RssSubscriptionUpdate? {
        val styling = if (readerMode) RssStyling.READER else RssStyling.NATIVE
        return if (subscription.defaultStyling == styling) null else RssSubscriptionUpdate(defaultStyling = styling)
    }

    /** The remote-content toggle writes an explicit `default_remote_content`, never `inherit`. */
    fun remoteContentUpdate(
        subscription: RssSubscription,
        allowed: Boolean,
    ): RssSubscriptionUpdate? {
        val mode = if (allowed) RssRemoteContentMode.SHOW else RssRemoteContentMode.HIDE
        return if (subscription.defaultRemoteContent == mode) {
            null
        } else {
            RssSubscriptionUpdate(defaultRemoteContent = mode)
        }
    }
}
