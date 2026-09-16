package com.cabalmail.android.navigation

import com.cabalmail.android.ui.feeds.FeedRoutes
import com.cabalmail.kit.models.NavState
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemScope
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The launch ladder and the cross-device prompt rule (resume-session plan, Phase B). */
class LaunchDestinationTest {
    private val identity: (String) -> String = { it }

    // ------------------------------------------------------------- mail

    @Test
    fun `nothing saved lands on INBOX where a launch used to, and stays on the hub where it did not`() {
        val phone =
            LaunchDestination.mailRoutes(
                null,
                compactWidth = true,
                launchIntoInbox = true,
                messageReachable = false,
                encode = identity,
            )
        assertEquals(listOf(LaunchRoute("messages/INBOX", MAIL_HUB_ROUTE)), phone)
        val medium =
            LaunchDestination.mailRoutes(
                null,
                compactWidth = false,
                launchIntoInbox = false,
                messageReachable = false,
                encode = identity,
            )
        assertTrue(medium.isEmpty())
    }

    @Test
    fun `a saved folder lands even where INBOX would not have`() {
        val session = ResumeSession(folder = "Archive")
        val routes =
            LaunchDestination.mailRoutes(
                session,
                compactWidth = false,
                launchIntoInbox = false,
                messageReachable = false,
                encode = identity,
            )
        assertEquals(listOf(LaunchRoute("messages/Archive", MAIL_HUB_ROUTE)), routes)
    }

    @Test
    fun `a reachable message is preselected on wide windows and pushed on phones`() {
        val session = ResumeSession(folder = "Archive", uid = 316, messageId = "<316@x>")
        val wide =
            LaunchDestination.mailRoutes(
                session,
                compactWidth = false,
                launchIntoInbox = true,
                messageReachable = true,
                encode = identity,
            )
        assertEquals(listOf(LaunchRoute("messages/Archive?uid=316", MAIL_HUB_ROUTE)), wide)
        val phone =
            LaunchDestination.mailRoutes(
                session,
                compactWidth = true,
                launchIntoInbox = true,
                messageReachable = true,
                encode = identity,
            )
        assertEquals(
            listOf(LaunchRoute("messages/Archive", MAIL_HUB_ROUTE), LaunchRoute("message/Archive/316", null)),
            phone,
        )
    }

    @Test
    fun `an unreachable message degrades to its folder`() {
        val session = ResumeSession(folder = "Archive", uid = 316)
        val routes =
            LaunchDestination.mailRoutes(
                session,
                compactWidth = true,
                launchIntoInbox = true,
                messageReachable = false,
                encode = identity,
            )
        assertEquals(listOf(LaunchRoute("messages/Archive", MAIL_HUB_ROUTE)), routes)
    }

    // ------------------------------------------------------------- feeds

    private val item = RssItem(feedId = "f1", sortKey = "2026-01-01T00:00:00+00:00#i1", itemId = "i1")

    @Test
    fun `a departed scope degrades to the feed tree`() {
        assertTrue(LaunchDestination.feedRoutes(null, item, compactWidth = true, encode = identity).isEmpty())
    }

    @Test
    fun `a scope with its item is preselected on wide windows and pushed on phones`() {
        val scope = RssItemScope.Subscription("s1")
        val wide = LaunchDestination.feedRoutes(scope, item, compactWidth = false, encode = identity)
        assertEquals(
            listOf(LaunchRoute("feeds/items/sub:s1?item=f1#2026-01-01T00:00:00+00:00#i1", FeedRoutes.HUB)),
            wide,
        )
        val phone = LaunchDestination.feedRoutes(scope, item, compactWidth = true, encode = identity)
        assertEquals(
            listOf(
                LaunchRoute("feeds/items/sub:s1", FeedRoutes.HUB),
                LaunchRoute("feeds/item/f1/2026-01-01T00:00:00+00:00#i1", null),
            ),
            phone,
        )
    }

    @Test
    fun `a pruned item degrades to its list`() {
        val routes = LaunchDestination.feedRoutes(RssItemScope.All, null, compactWidth = true, encode = identity)
        assertEquals(listOf(LaunchRoute("feeds/items/all", FeedRoutes.HUB)), routes)
    }

    // ------------------------------------------------------------- foreign cursor

    private fun cursor(
        folder: String? = "Archive",
        uid: Long? = 316,
        messageId: String? = null,
        clientId: String? = "other-install",
        updatedAt: Long? = 2_000,
    ) = NavState(folder = folder, uid = uid, messageId = messageId, clientId = clientId, updatedAt = updatedAt)

    @Test
    fun `only a foreign, newer cursor at a different place is offered`() {
        val session = ResumeSession(folder = "INBOX")
        assertTrue(
            ForeignCursorPolicy.shouldOffer(cursor(), "this-install", offeredWatermark = 1_000, session = session),
        )
        assertFalse(
            ForeignCursorPolicy.shouldOffer(cursor(clientId = "this-install"), "this-install", 0, session),
            "own cursor",
        )
        assertFalse(
            ForeignCursorPolicy.shouldOffer(cursor(clientId = ""), "this-install", 0, session),
            "unknown origin",
        )
        assertFalse(
            ForeignCursorPolicy.shouldOffer(cursor(updatedAt = 2_000), "this-install", 2_000, session),
            "already offered",
        )
        assertFalse(ForeignCursorPolicy.shouldOffer(cursor(updatedAt = null), "this-install", 0, session), "no recency")
        assertFalse(ForeignCursorPolicy.shouldOffer(cursor(folder = null), "this-install", 0, session), "no folder")
    }

    @Test
    fun `same place matches by Message-ID first then UID and needs both sides to agree on a message`() {
        val open = ResumeSession(folder = "Archive", uid = 316, messageId = "<316@x>")
        assertTrue(ForeignCursorPolicy.samePlace(cursor(uid = 999, messageId = "<316@x>"), open), "Message-ID wins")
        assertTrue(ForeignCursorPolicy.samePlace(cursor(uid = 316), open), "UID when the cursor has no Message-ID")
        assertFalse(ForeignCursorPolicy.samePlace(cursor(messageId = "<317@x>", uid = null), open))
        assertFalse(ForeignCursorPolicy.samePlace(cursor(uid = null), open), "folder-only cursor vs an open message")
        assertFalse(ForeignCursorPolicy.samePlace(cursor(folder = "INBOX", messageId = "<316@x>"), open))
        assertTrue(
            ForeignCursorPolicy.samePlace(cursor(uid = null), ResumeSession(folder = "Archive")),
            "folder-only on both sides",
        )
        assertFalse(
            ForeignCursorPolicy.samePlace(
                cursor(),
                ResumeSession(section = ResumeSection.FEEDS, folder = "Archive", uid = 316),
            ),
            "a feeds session restores the feed reader, not this message",
        )
        assertFalse(ForeignCursorPolicy.samePlace(cursor(), null))
        assertFalse(
            ForeignCursorPolicy.shouldOffer(cursor(), "this-install", 0, open),
            "the same place is never offered",
        )
    }
}
