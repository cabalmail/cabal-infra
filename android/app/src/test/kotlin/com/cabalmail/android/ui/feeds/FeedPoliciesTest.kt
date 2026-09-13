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
