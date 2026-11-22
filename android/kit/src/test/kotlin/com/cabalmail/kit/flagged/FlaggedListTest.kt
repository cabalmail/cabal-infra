package com.cabalmail.kit.flagged

import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.ItemRef
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.SearchFilters
import com.cabalmail.kit.models.ref
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import java.time.Instant

/**
 * The Flagged view's list (`docs/1.x/post-wave-3/android-parity.md`, leg
 * L4): one order across both media, and the horizon that keeps the list
 * from showing anything older than the point a half still loading is
 * complete down to.
 */
class FlaggedListTest {
    private fun mail(
        uid: Long,
        date: String,
        folder: String? = "INBOX",
    ) = Envelope(id = uid, date = date, folder = folder, flags = listOf("\\Flagged"))

    private fun feed(
        id: String,
        publishedAt: String,
    ) = RssItem(
        feedId = "f1",
        sortKey = "$publishedAt#$id",
        itemId = id,
        publishedAt = publishedAt,
        isFavorite = true,
    )

    /** Each row as `m<uid>` or the feed item's id, in list order. */
    private fun FlaggedPage.names(): List<String> =
        rows.map { row ->
            when (row) {
                is FlaggedRow.Mail -> "m${row.envelope.id}"
                is FlaggedRow.Feed -> row.item.itemId
            }
        }

    private fun whole(
        mail: List<Envelope>,
        feed: List<RssItem>,
    ) = FlaggedList.merge(
        mail,
        FlaggedList.mailCutoff(mail, hasMore = false),
        feed,
        FlaggedList.feedCutoff(feed, false),
    )

    private fun mailPaging(
        mail: List<Envelope>,
        feed: List<RssItem>,
    ) = FlaggedList.merge(mail, FlaggedList.mailCutoff(mail, hasMore = true), feed, null)

    @Test
    fun `whole halves interleave by date across media`() {
        val page =
            whole(
                // The server's order is by arrival day, then folder and UID: not this list's order.
                mail =
                    listOf(
                        mail(3, "2026-03-05 08:00:00"),
                        mail(9, "2026-03-05 21:00:00"),
                        mail(1, "2026-03-01 12:00:00"),
                    ),
                feed = listOf(feed("a", "2026-03-05T12:00:00+00:00"), feed("b", "2026-03-03T00:00:00+00:00")),
            )
        assertEquals(listOf("m9", "a", "m3", "b", "m1"), page.names())
        assertNull(page.cutoff)
        assertNull(page.next)
        assertEquals(0, page.heldBack)
    }

    @Test
    fun `an offset in a message's date is honoured when ordering`() {
        // 23:30 at -05:00 is 04:30 the next day in UTC, after the feed item.
        val page =
            whole(
                mail = listOf(mail(1, "2026-03-05 23:30:00-05:00")),
                feed = listOf(feed("a", "2026-03-06T01:00:00+00:00")),
            )
        assertEquals(listOf("m1", "a"), page.names())
    }

    @Test
    fun `a row with no date sorts last, and one with no folder is left out`() {
        val page =
            whole(
                mail =
                    listOf(
                        mail(1, "None"),
                        mail(2, "2026-03-01 12:00:00"),
                        mail(3, "2026-03-02 12:00:00", folder = null),
                    ),
                feed = listOf(feed("a", ""), feed("b", "2026-02-01T00:00:00+00:00")),
            )
        assertEquals(listOf("m2", "b", "a", "m1"), page.names())
    }

    @Test
    fun `rows of one instant keep one order however they arrive`() {
        val a = mail(1, "2026-03-01 12:00:00")
        val b = mail(2, "2026-03-01 12:00:00", folder = "Archive")
        val c = feed("x", "2026-03-01T12:00:00+00:00")
        assertEquals(whole(listOf(a, b), listOf(c)).names(), whole(listOf(b, a), listOf(c)).names())
    }

    @Test
    fun `while mail has more pages the list ends at the midnight after the last row's day`() {
        val mail =
            listOf(
                mail(5, "2026-03-07 09:00:00"),
                mail(4, "2026-03-06 23:59:59"),
                // The page ends inside 5 March: more of that day may be on the next page.
                mail(3, "2026-03-05 18:00:00"),
                mail(2, "2026-03-05 02:00:00"),
            )
        val feed =
            listOf(
                feed("new", "2026-03-06T00:00:00+00:00"),
                feed("sameDay", "2026-03-05T23:00:00+00:00"),
                feed("old", "2026-01-01T00:00:00+00:00"),
            )
        val page = mailPaging(mail, feed)
        assertEquals(Instant.parse("2026-03-06T00:00:00Z"), page.cutoff)
        // Nothing of 5 March or before, from either medium; midnight itself is whole.
        assertEquals(listOf("m5", "m4", "new"), page.names())
        assertEquals(FlaggedSource.MAIL, page.next)
        assertEquals(4, page.heldBack)
    }

    @Test
    fun `the next page releases what the horizon held back`() {
        val first = listOf(mail(5, "2026-03-07 09:00:00"), mail(3, "2026-03-05 18:00:00"))
        val feed = listOf(feed("sameDay", "2026-03-05T23:00:00+00:00"), feed("old", "2026-01-01T00:00:00+00:00"))
        assertEquals(listOf("m5"), mailPaging(first, feed).names())

        val second = first + listOf(mail(2, "2026-03-05 20:00:00"), mail(1, "2026-02-01 00:00:00"))
        val paging = mailPaging(second, feed)
        // 5 March is whole now: its feed item, and both its messages in time order.
        assertEquals(listOf("m5", "sameDay", "m2", "m3"), paging.names())
        assertEquals(Instant.parse("2026-02-02T00:00:00Z"), paging.cutoff)

        // The last page: no horizon, and the oldest rows of both media.
        assertEquals(listOf("m5", "sameDay", "m2", "m3", "m1", "old"), whole(second, feed).names())
    }

    @Test
    fun `a page that is all one day shows none of it yet`() {
        val mail = listOf(mail(2, "2026-03-05 18:00:00"), mail(1, "2026-03-05 02:00:00"))
        val feed = listOf(feed("newer", "2026-03-06T10:00:00+00:00"), feed("older", "2026-03-04T10:00:00+00:00"))
        val page = mailPaging(mail, feed)
        assertEquals(listOf("newer"), page.names())
        assertEquals(3, page.heldBack)
    }

    @Test
    fun `the horizon reads past a last row that has no date`() {
        val mail = listOf(mail(3, "2026-03-07 09:00:00"), mail(2, "2026-03-05 18:00:00"), mail(1, "None"))
        assertEquals(Instant.parse("2026-03-06T00:00:00Z"), FlaggedList.mailCutoff(mail, hasMore = true))
    }

    @Test
    fun `with pages left and no dated message nothing is vouched for`() {
        val mail = listOf(mail(1, "None"))
        val feed = listOf(feed("a", "2026-03-06T10:00:00+00:00"))
        val page = mailPaging(mail, feed)
        assertEquals(emptyList<String>(), page.names())
        assertEquals(FlaggedSource.MAIL, page.next)
        assertEquals(2, page.heldBack)
        // The same holds before any page has landed.
        assertEquals(emptyList<String>(), mailPaging(emptyList(), feed).names())
    }

    @Test
    fun `mail that never loaded leaves the feed half whole`() {
        // Offline: no page, and no claim that there are more.
        val page =
            whole(emptyList(), listOf(feed("a", "2026-03-06T10:00:00+00:00"), feed("b", "2020-01-01T00:00:00+00:00")))
        assertEquals(listOf("a", "b"), page.names())
        assertNull(page.cutoff)
    }

    @Test
    fun `a feed half still being read ends just past its last row`() {
        val feed =
            listOf(
                feed("a", "2026-03-06T10:00:00+00:00"),
                // Another item published in this instant may be on the next read.
                feed("b", "2026-03-04T10:00:00+00:00"),
            )
        val mail = listOf(mail(2, "2026-03-05 12:00:00"), mail(1, "2026-03-04 10:00:00"))
        val page = FlaggedList.merge(mail, null, feed, FlaggedList.feedCutoff(feed, hasMore = true))
        assertEquals(listOf("a", "m2"), page.names())
        assertEquals(FlaggedSource.FEED, page.next)
        assertEquals(2, page.heldBack)
    }

    @Test
    fun `with both halves loading the later horizon binds and names what to load`() {
        val mail = listOf(mail(2, "2026-03-09 12:00:00"), mail(1, "2026-03-08 12:00:00"))
        val feed = listOf(feed("a", "2026-03-09T18:00:00+00:00"), feed("b", "2026-03-02T00:00:00+00:00"))
        val mailBinds =
            FlaggedList.merge(mail, FlaggedList.mailCutoff(mail, true), feed, FlaggedList.feedCutoff(feed, true))
        assertEquals(Instant.parse("2026-03-09T00:00:00Z"), mailBinds.cutoff)
        assertEquals(FlaggedSource.MAIL, mailBinds.next)
        assertEquals(listOf("a", "m2"), mailBinds.names())

        val recent = listOf(feed("a", "2026-03-09T18:00:00+00:00"))
        val feedBinds =
            FlaggedList.merge(mail, FlaggedList.mailCutoff(mail, true), recent, FlaggedList.feedCutoff(recent, true))
        assertEquals(FlaggedSource.FEED, feedBinds.next)
        assertEquals(emptyList<String>(), feedBinds.names())
    }

    @Test
    fun `each criterion asks the server for its own flag and nothing else`() {
        assertEquals(SearchFilters(anyFlag = true), FlagCriterion.AnyFlag.mailSearch())
        assertEquals(SearchFilters(flagged = true), FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT).mailSearch())
        assertEquals(SearchFilters(keyword = "cabal-flag-07"), FlagCriterion.Slot("cabal-flag-07").mailSearch())
        // The server answers 400 to a keyword that is not a slot; it is never sent.
        assertNull(FlagCriterion.Slot("cabal-flag-21").mailSearch())
        assertNull(FlagCriterion.Slot("\$Forwarded").mailSearch())
    }

    @Test
    fun `a ref tells a message from a feed item and one folder from another`() {
        val inbox = mail(7, "None").ref()
        assertEquals(ItemRef.Mail("INBOX", 7), inbox)
        assertNotEquals(inbox, mail(7, "None", folder = "Archive").ref())
        assertNull(mail(7, "None", folder = null).ref())
        assertEquals(ItemRef.Mail("Sent", 7), mail(7, "None", folder = null).ref("Sent"))

        val item = feed("7", "2026-03-01T00:00:00+00:00")
        assertEquals(ItemRef.Feed("f1", "2026-03-01T00:00:00+00:00#7"), item.ref)
        // A feed whose id reads like a folder cannot share a key with that folder's message.
        assertNotEquals(ItemRef.Mail("INBOX", 7).key, ItemRef.Feed("INBOX", "7").key)
    }

    @Test
    fun `a ref comes back from its key`() {
        val refs =
            listOf(
                ItemRef.Mail("INBOX", 7),
                // A nested folder's path holds the separator the key uses.
                ItemRef.Mail("Clients/Acme/2026", 12),
                ItemRef.Mail("feed:odd", 1),
                // A sort key holds the separator too, after the feed id.
                ItemRef.Feed("f1", "2026-03-01T00:00:00+00:00#i1"),
                ItemRef.Feed("f1", "a#b#c"),
            )
        refs.forEach { assertEquals(it, ItemRef.parse(it.key), it.key) }

        listOf(
            "",
            "INBOX/7",
            "mail:",
            "mail:INBOX",
            "mail:/7",
            "mail:INBOX/x",
            "feed:",
            "feed:f1",
            "feed:#k",
            "feed:f1#",
        ).forEach {
            assertNull(ItemRef.parse(it), "'$it' names nothing")
        }
    }
}
