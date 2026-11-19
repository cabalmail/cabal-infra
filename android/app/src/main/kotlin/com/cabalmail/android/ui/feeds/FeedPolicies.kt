package com.cabalmail.android.ui.feeds

import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.FlagFilterMenu
import com.cabalmail.android.ui.theme.UiLabel
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import com.cabalmail.kit.settings.FeedSwipeAction
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import com.cabalmail.kit.settings.LoadRemoteContent

/**
 * Words on the feed list that depend on which flag a control sets.
 */
object FeedFlagWords {
    /**
     * Whether the empty Flagged list may offer the swipe as a way to flag
     * an item. The swipe sets the default flag, and the lit pill shows the
     * built-in flag, or the flag [pick] names, or any flag at all: the
     * hint holds only while the swipe would put an item in the list, and
     * an edge is bound to the flag swipe. Otherwise the row's menu is the
     * way, and the words say so.
     */
    fun flaggedPillOffersSwipe(
        palette: List<FlagPaletteEntry>,
        leading: FeedSwipeAction,
        trailing: FeedSwipeAction,
        pick: FlagCriterion? = null,
    ): Boolean {
        val shown = pick ?: FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)
        return shown.matches(listOf(FlagPalette.defaultEntry(palette).slot)) &&
            FeedSwipeAction.TOGGLE_FAVORITE in listOf(leading, trailing)
    }

    /**
     * The empty list's title under the lit Flagged pill: the picked flag
     * by name, or that nothing is flagged, which is also what the
     * built-in flag's own filter has always said.
     */
    internal fun emptyTitle(
        palette: List<FlagPaletteEntry>,
        pick: FlagCriterion?,
    ): UiLabel =
        when (pick) {
            null, FlagCriterion.AnyFlag -> UiLabel.Fixed(R.string.feed_empty_favorite_title)
            is FlagCriterion.Slot ->
                UiLabel.Formatted(
                    R.string.feed_empty_flag_title,
                    FlagFilterMenu.name(palette, pick),
                )
        }

    /**
     * The pill a tap on Unread leaves. With no pick it is the toggle it
     * always was. Over a pick it ends the pick and shows Unread, whatever
     * the feed remembered: the pick had the list, so the tap is a choice
     * of Unread.
     */
    fun unreadTap(
        filter: RssItemFilter,
        pick: FlagCriterion?,
    ): RssItemFilter = if (pick != null) RssItemFilter.UNREAD else filter.toggling(RssItemFilter.UNREAD)
}

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

    /**
     * Whether a finished page is rendered in the reader. The toggle asks for
     * the reader for the whole feed, so the request is still on after a link
     * out of it: the page the user followed a link to stays as the publisher
     * served it until the reader is asked for again (#2060). The feed's saved
     * styling is untouched either way, so the next item still opens in the
     * reader. The Apple `ArticleNavigationPolicy.showsReader`.
     */
    fun showsReader(
        wantsReader: Boolean,
        leftThroughLink: Boolean,
    ): Boolean = wantsReader && !leftThroughLink

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
