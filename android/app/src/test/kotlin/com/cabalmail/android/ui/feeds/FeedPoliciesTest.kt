package com.cabalmail.android.ui.feeds

import com.cabalmail.android.R
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
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The sticky-pill and reader-defaults policies, mirroring the Apple `FeedListStickyFilterTests` and `FeedDetailPolicyTests`. */
class FeedPoliciesTest {
    private val sub = RssSubscription("s1", "f1", defaultFilter = RssItemFilter.FAVORITE)
    private val folder = RssFolder("d1", name = "News", defaultFilter = RssItemFilter.ALL)

    @Test
    fun `the initial pill comes from the scope's row, else Unread, never All`() {
        assertEquals(
            RssItemFilter.FAVORITE,
            FeedListFilterPolicy.initial(RssItemScope.Subscription("s1"), sub, null, RssItemFilter.ALL),
        )
        assertEquals(
            RssItemFilter.ALL,
            FeedListFilterPolicy.initial(RssItemScope.Folder("d1"), null, folder, RssItemFilter.FAVORITE),
        )
        assertEquals(
            RssItemFilter.FAVORITE,
            FeedListFilterPolicy.initial(RssItemScope.All, null, null, RssItemFilter.FAVORITE),
        )
        assertEquals(
            RssItemFilter.UNREAD,
            FeedListFilterPolicy.initial(RssItemScope.Subscription("s1"), null, null, RssItemFilter.ALL),
        )
        assertEquals(
            RssItemFilter.UNREAD,
            FeedListFilterPolicy.initial(RssItemScope.Folder("d1"), null, null, RssItemFilter.ALL),
        )
    }

    @Test
    fun `the sticky update is null when the row already says so`() {
        assertNull(FeedListFilterPolicy.stickyUpdate(sub, RssItemFilter.FAVORITE))
        assertEquals(
            RssSubscriptionUpdate(defaultFilter = RssItemFilter.ALL),
            FeedListFilterPolicy.stickyUpdate(sub, RssItemFilter.ALL),
        )
        assertNull(FeedListFilterPolicy.stickyUpdate(folder, RssItemFilter.ALL))
        assertEquals(
            RssFolderUpdate(defaultFilter = RssItemFilter.UNREAD),
            FeedListFilterPolicy.stickyUpdate(folder, RssItemFilter.UNREAD),
        )
    }

    @Test
    fun `reader defaults are summary in reader styling with remote content off`() {
        val initial = FeedDetailPolicy.initial(null, hasArticleUrl = true, globalRemoteContent = LoadRemoteContent.OFF)
        assertEquals(FeedDetailInitial(showsArticle = false, readerMode = true, remoteContentAllowed = false), initial)
    }

    @Test
    fun `remote content inherits the app preference unless the feed overrides it`() {
        fun allowed(
            mode: RssRemoteContentMode,
            global: LoadRemoteContent,
        ) = FeedDetailPolicy.initial(sub.copy(defaultRemoteContent = mode), true, global).remoteContentAllowed
        assertFalse(allowed(RssRemoteContentMode.INHERIT, LoadRemoteContent.OFF))
        assertFalse(allowed(RssRemoteContentMode.INHERIT, LoadRemoteContent.ASK))
        assertTrue(allowed(RssRemoteContentMode.INHERIT, LoadRemoteContent.ALWAYS))
        assertTrue(allowed(RssRemoteContentMode.SHOW, LoadRemoteContent.OFF))
        assertFalse(allowed(RssRemoteContentMode.HIDE, LoadRemoteContent.ALWAYS))
    }

    @Test
    fun `article mode needs a link`() {
        val article = sub.copy(defaultOpenMode = RssOpenMode.ARTICLE, defaultStyling = RssStyling.NATIVE)
        assertTrue(FeedDetailPolicy.initial(article, true, LoadRemoteContent.OFF).showsArticle)
        val noLink = FeedDetailPolicy.initial(article, false, LoadRemoteContent.OFF)
        assertFalse(noLink.showsArticle)
        assertFalse(noLink.readerMode)
    }

    @Test
    fun `each toggle writes only its own field and nothing when the row already matches`() {
        val articleUpdate = FeedDetailPolicy.articleUpdate(sub, showingArticle = true, hasArticleUrl = true)
        assertEquals(RssSubscriptionUpdate(defaultOpenMode = RssOpenMode.ARTICLE), articleUpdate)
        assertNull(FeedDetailPolicy.articleUpdate(sub, showingArticle = false, hasArticleUrl = true))
        assertNull(
            FeedDetailPolicy.articleUpdate(sub, showingArticle = true, hasArticleUrl = false),
            "no open mode without an article",
        )
        assertEquals(
            RssSubscriptionUpdate(defaultStyling = RssStyling.NATIVE),
            FeedDetailPolicy.stylingUpdate(sub, readerMode = false),
        )
        assertNull(FeedDetailPolicy.stylingUpdate(sub, readerMode = true))
        // An explicit choice pins the feed even when the visible effect is unchanged.
        assertEquals(
            RssSubscriptionUpdate(defaultRemoteContent = RssRemoteContentMode.HIDE),
            FeedDetailPolicy.remoteContentUpdate(sub, allowed = false),
        )
        assertNull(
            FeedDetailPolicy.remoteContentUpdate(
                sub.copy(defaultRemoteContent = RssRemoteContentMode.HIDE),
                allowed = false,
            ),
        )
    }

    @Test
    fun `a page reached through a link in the reader is not put back in it`() {
        // The toggle asks for the reader for the whole feed, so the request
        // is still on after a link out of it (#2060).
        assertFalse(FeedDetailPolicy.showsReader(wantsReader = true, leftThroughLink = true))
        // The negative control: the same request on a page nobody linked out
        // to still renders the reader, so "never show the reader" cannot pass.
        assertTrue(FeedDetailPolicy.showsReader(wantsReader = true, leftThroughLink = false))
        assertFalse(FeedDetailPolicy.showsReader(wantsReader = false, leftThroughLink = false))
        assertFalse(FeedDetailPolicy.showsReader(wantsReader = false, leftThroughLink = true))
    }

    @Test
    fun `the empty Flagged list offers the swipe only while the swipe sets the flag that pill shows`() {
        val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
        val builtIn = FlagPalette.DEFAULT_SYSTEM_ENTRY
        val flag = FeedSwipeAction.TOGGLE_FAVORITE
        val read = FeedSwipeAction.TOGGLE_READ
        val none = FeedSwipeAction.NONE

        // The built-in flag is the default one: with no flag of the user's
        // own, with one after it (a list that stores no built-in entry
        // leads with it), and stored first.
        assertTrue(FeedFlagWords.flaggedPillOffersSwipe(emptyList(), leading = read, trailing = flag))
        assertTrue(FeedFlagWords.flaggedPillOffersSwipe(listOf(urgent), leading = read, trailing = flag))
        assertTrue(FeedFlagWords.flaggedPillOffersSwipe(listOf(builtIn, urgent), leading = flag, trailing = none))
        // Another flag was made the default: the swipe sets that one,
        // which the Flagged pill does not show.
        assertFalse(FeedFlagWords.flaggedPillOffersSwipe(listOf(urgent, builtIn), leading = read, trailing = flag))
        // No edge is bound to the flag swipe.
        assertFalse(FeedFlagWords.flaggedPillOffersSwipe(emptyList(), leading = read, trailing = none))
    }

    @Test
    fun `under a pick the empty list offers the swipe only while the swipe sets the picked flag`() {
        val urgent = FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red")
        val later = FlagPaletteEntry(slot = "cabal-flag-02", label = "Later", color = "blue")
        val flag = FeedSwipeAction.TOGGLE_FAVORITE
        val read = FeedSwipeAction.TOGGLE_READ

        fun offers(
            palette: List<FlagPaletteEntry>,
            pick: FlagCriterion,
            trailing: FeedSwipeAction = flag,
        ) = FeedFlagWords.flaggedPillOffersSwipe(palette, leading = read, trailing = trailing, pick = pick)

        // Urgent leads the list, so the swipe sets Urgent.
        val urgentFirst = listOf(urgent, FlagPalette.DEFAULT_SYSTEM_ENTRY, later)
        assertTrue(offers(urgentFirst, FlagCriterion.Slot(urgent.slot)))
        assertFalse(offers(urgentFirst, FlagCriterion.Slot(later.slot)))
        assertFalse(offers(urgentFirst, FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)))
        // Any flag is lit: whichever flag the swipe sets, the item joins the list.
        assertTrue(offers(urgentFirst, FlagCriterion.AnyFlag))
        assertTrue(offers(listOf(later), FlagCriterion.AnyFlag))
        assertFalse(offers(urgentFirst, FlagCriterion.AnyFlag, trailing = FeedSwipeAction.NONE))
        // The built-in flag leads: a pick of another flag gets the menu's words.
        assertFalse(offers(listOf(later), FlagCriterion.Slot(later.slot)))
    }

    @Test
    fun `the empty list under a pick names the flag, and Unread over a pick is a choice of Unread`() {
        val later = FlagPaletteEntry(slot = "cabal-flag-02", label = "Later", color = "blue")

        assertEquals(UiLabel.Fixed(R.string.feed_empty_favorite_title), FeedFlagWords.emptyTitle(listOf(later), null))
        assertEquals(
            UiLabel.Fixed(R.string.feed_empty_favorite_title),
            FeedFlagWords.emptyTitle(listOf(later), FlagCriterion.AnyFlag),
        )
        assertEquals(
            UiLabel.Formatted(R.string.feed_empty_flag_title, "Later"),
            FeedFlagWords.emptyTitle(listOf(later), FlagCriterion.Slot(later.slot)),
        )

        val pick = FlagCriterion.Slot(later.slot)
        assertEquals(
            RssItemFilter.UNREAD,
            FeedFlagWords.unreadTap(RssItemFilter.UNREAD, pick),
            "not a toggle back to All",
        )
        assertEquals(RssItemFilter.UNREAD, FeedFlagWords.unreadTap(RssItemFilter.FAVORITE, FlagCriterion.AnyFlag))
        assertEquals(RssItemFilter.ALL, FeedFlagWords.unreadTap(RssItemFilter.UNREAD, pick = null))
        assertEquals(RssItemFilter.UNREAD, FeedFlagWords.unreadTap(RssItemFilter.ALL, pick = null))
    }

    @Test
    fun `item ids split back into feed and sort key`() {
        assertEquals("f1" to "2026-01-01T00:00:00+00:00#i1", FeedRoutes.splitItemId("f1#2026-01-01T00:00:00+00:00#i1"))
        assertNull(FeedRoutes.splitItemId("nohash"))
        assertNull(FeedRoutes.splitItemId("#k"))
        assertNull(FeedRoutes.splitItemId("f1#"))
    }

    @Test
    fun `dates read relative in the list and empty when unparseable`() {
        val now = java.time.Instant.parse("2026-09-13T12:00:00Z")
        assertEquals("now", FeedItemDate.relative("2026-09-13T11:59:40+00:00", now))
        assertEquals("5m", FeedItemDate.relative("2026-09-13T11:55:00+00:00", now))
        assertEquals("3h", FeedItemDate.relative("2026-09-13T09:00:00+00:00", now))
        assertEquals("2h", FeedItemDate.relative("2026-09-13T09:00:00.123+00:00", now), "fractional seconds parse")
        assertEquals("2d", FeedItemDate.relative("2026-09-11T09:00:00Z", now))
        assertEquals("", FeedItemDate.relative("not a date", now))
        assertEquals("", FeedItemDate.absolute(""))
    }
}
