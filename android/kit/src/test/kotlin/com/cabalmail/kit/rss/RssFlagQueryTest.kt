package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The Flagged pill's pick over cached feed items
 * (`docs/1.x/post-wave-3/flags-and-cross-media.md`, decision 4): which
 * items a criterion finds, as the predicate the in-memory store runs and
 * as the SQL the Room store runs, over the same rows, on real SQLite built
 * from the exported schema.
 */
class RssFlagQueryTest {
    private val later = "cabal-flag-01"
    private val work = "cabal-flag-02"
    private val eleven = "cabal-flag-11"

    private fun item(
        n: Int,
        isFavorite: Boolean = false,
        flags: Set<String> = emptySet(),
        isRead: Boolean = false,
    ) = RssItem(
        feedId = "f1",
        sortKey = "2026-01-0${n}T10:00:00+00:00#i$n",
        itemId = "i$n",
        publishedAt = "2026-01-0${n}T10:00:00+00:00",
        isFavorite = isFavorite,
        flags = flags,
        isRead = isRead,
        isReadExplicit = true,
    )

    private val items =
        listOf(
            item(1),
            item(2, isFavorite = true),
            item(3, flags = setOf(later)),
            item(4, isFavorite = true, flags = setOf(later, work), isRead = true),
            item(5, flags = setOf(eleven)),
            item(6, flags = setOf(work), isRead = true),
        )

    private val criteria =
        mapOf(
            FlagCriterion.Slot(later) to listOf("i3", "i4"),
            FlagCriterion.Slot(work) to listOf("i4", "i6"),
            FlagCriterion.Slot(eleven) to listOf("i5"),
            // `cabal-flag-01` is no part of `cabal-flag-11`, nor the other way.
            FlagCriterion.Slot("cabal-flag-1") to emptyList(),
            FlagCriterion.Slot("cabal-flag-03") to emptyList(),
            FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT) to listOf("i2", "i4"),
            FlagCriterion.AnyFlag to listOf("i2", "i3", "i4", "i5", "i6"),
            // Not a palette slot: never looked for, whatever the rows hold.
            FlagCriterion.Slot("%") to emptyList(),
            FlagCriterion.Slot("") to emptyList(),
            FlagCriterion.Slot("flags") to emptyList(),
        )

    @Test
    fun `the predicate finds the items that carry the pick`() {
        for ((criterion, expected) in criteria) {
            assertEquals(expected, items.filter { RssFlagQuery.matches(criterion, it) }.map { it.itemId }, "$criterion")
        }
        assertEquals(items, items.filter { RssFlagQuery.matches(null, it) }, "no pick narrows nothing")
    }

    @Test
    fun `the SQL finds the same items on real SQLite`() {
        val database = ExportedSchema.created(RssDatabase.VERSION)
        for (item in items) {
            database.run(
                "INSERT INTO rss_items (feed_id, sort_key, item_id, guid, title, author, url, published_at, " +
                    "updated_at, fetched_at, fetched_key, summary_html, content_html, body_text, is_read, " +
                    "is_favorite, state_is_explicit, cached_at, flags) VALUES (?, ?, ?, '', '', '', '', '', '', '', " +
                    "'', '', '', '', 0, ?, 1, '', ?)",
                item.feedId,
                item.sortKey,
                item.itemId,
                if (item.isFavorite) 1 else 0,
                RssStoredFlags.encode(item.flags),
            )
        }

        for ((criterion, expected) in criteria) {
            val clause = RssFlagQuery.clause(criterion)
            val found =
                if (clause == null) {
                    emptyList()
                } else {
                    database
                        .rows(
                            "SELECT i.item_id FROM rss_items i WHERE ${clause.sql} ORDER BY i.id",
                            *clause.binds.toTypedArray(),
                        ).map { it.single() }
                }
            assertEquals(expected, found, "$criterion")
        }
    }

    @Test
    fun `a slot that is not a palette slot has no clause at all`() {
        assertNull(RssFlagQuery.clause(FlagCriterion.Slot("%")))
        assertNull(RssFlagQuery.clause(FlagCriterion.Slot("cabal-flag-21")))
        assertNull(RssFlagQuery.clause(FlagCriterion.Slot("\\Seen")))
        // Its text never reaches the statement: a slot is bound, not spliced in.
        val clause = RssFlagQuery.clause(FlagCriterion.Slot(later))!!
        assertFalse(later in clause.sql)
        assertEquals(listOf("%\"$later\"%"), clause.binds)
    }

    @Test
    fun `a criterion reads a message's flag list as it reads a feed item's`() {
        val mail = listOf("\\Seen", "\\flagged", work, "\$Forwarded")

        assertTrue(FlagCriterion.Slot(work).matches(mail))
        assertTrue(FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT).matches(mail), "the built-in flag's atom in any case")
        assertFalse(FlagCriterion.Slot(later).matches(mail))
        assertTrue(FlagCriterion.AnyFlag.matches(mail))
        assertTrue(FlagCriterion.AnyFlag.matches(listOf("\\Seen", later)), "a slot alone is a flag")
        assertFalse(FlagCriterion.AnyFlag.matches(listOf("\\Seen", "\\Answered", "\$Forwarded", "cabal-flag-21")))
    }

    // ------------------------------------------------------------ the store

    private suspend fun store() =
        InMemoryRssStore().also {
            it.upsertSubscription(RssSubscription(subscriptionId = "s1", feedId = "f1"))
            it.upsertSubscription(RssSubscription(subscriptionId = "s2", feedId = "f2"))
            it.upsertItems(items + item(7, flags = setOf(later)).copy(feedId = "f2"))
        }

    private suspend fun RssStore.ids(query: ItemQuery) = items(query).map { "${it.feedId}/${it.itemId}" }

    @Test
    fun `a page is narrowed by the pick, in the scope and the order asked for`() =
        runTest {
            val store = store()
            val feed = RssItemScope.Subscription("s1")

            assertEquals(
                listOf("f1/i4", "f1/i3"),
                store.ids(ItemQuery(feed, RssItemFilter.ALL, flag = FlagCriterion.Slot(later))),
                "newest first, this feed only",
            )
            assertEquals(
                listOf("f2/i7", "f1/i4", "f1/i3"),
                store.ids(ItemQuery(RssItemScope.All, RssItemFilter.ALL, flag = FlagCriterion.Slot(later))),
            )
            assertEquals(
                listOf("f1/i6", "f1/i5", "f1/i4", "f1/i3", "f1/i2"),
                store.ids(ItemQuery(feed, RssItemFilter.ALL, flag = FlagCriterion.AnyFlag)),
            )
            assertEquals(
                listOf("f1/i3"),
                store.ids(ItemQuery(feed, RssItemFilter.ALL, flag = FlagCriterion.AnyFlag, limit = 1, offset = 3)),
                "paged as any list is",
            )
            assertEquals(emptyList<String>(), store.ids(ItemQuery(feed, flag = FlagCriterion.Slot("%"))))
        }

    @Test
    fun `the pick narrows beside the pill, and a flag set here is found at once`() =
        runTest {
            val store = store()
            val feed = RssItemScope.Subscription("s1")

            assertEquals(
                listOf("f1/i5", "f1/i3", "f1/i2"),
                store.ids(ItemQuery(feed, RssItemFilter.UNREAD, flag = FlagCriterion.AnyFlag)),
                "both must hold",
            )

            store.setFlag("f1", item(1).sortKey, work, true)
            store.setFlag("f1", item(6).sortKey, work, false)

            assertEquals(
                listOf("f1/i4", "f1/i1"),
                store.ids(ItemQuery(feed, RssItemFilter.ALL, flag = FlagCriterion.Slot(work))),
            )
        }
}
