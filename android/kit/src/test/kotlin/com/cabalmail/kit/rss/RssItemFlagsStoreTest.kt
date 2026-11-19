package com.cabalmail.kit.rss

import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemState
import com.cabalmail.kit.models.RssSubscription
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * What an [RssStore] does with a feed item's flags of the user's own: the
 * part of the contract the Room store's SQL mirrors
 * (`docs/1.x/cross-media-ux-plan.md`, Phase 2b). A local change writes the
 * item and one queue row per item and slot; what the server reports is laid
 * under the queued changes, slot by slot.
 */
class RssItemFlagsStoreTest {
    private val later = "cabal-flag-01"
    private val work = "cabal-flag-02"
    private val urgent = "cabal-flag-03"

    private fun item(
        n: Int,
        flags: Set<String> = emptySet(),
    ) = RssItem(
        feedId = "f1",
        sortKey = "2026-01-0${n}T10:00:00+00:00#i$n",
        itemId = "i$n",
        publishedAt = "2026-01-0${n}T10:00:00+00:00",
        flags = flags,
    )

    private suspend fun store(vararg items: RssItem): InMemoryRssStore =
        InMemoryRssStore().also {
            it.upsertSubscription(RssSubscription(subscriptionId = "s1", feedId = "f1"))
            it.upsertItems(items.toList())
        }

    private suspend fun RssStore.flagsOf(item: RssItem) = item(item.feedId, item.sortKey)?.flags

    private fun state(
        item: RssItem,
        flags: Set<String>,
    ) = RssItemState(feedId = item.feedId, sortKey = item.sortKey, flags = flags)

    private suspend fun RssStore.flagRows() = pendingMutations().filter { it.kind == PendingKind.FLAG }

    @Test
    fun `a flag set here is on the item and in the queue, by slot`() =
        runTest {
            val store = store(item(1))

            store.setFlag("f1", item(1).sortKey, later, true)

            assertEquals(setOf(later), store.flagsOf(item(1)))
            val row = store.pendingMutations().single()
            assertEquals(PendingKind.FLAG, row.kind)
            assertEquals(later, row.slot)
            assertTrue(row.value, "an add")
            assertTrue(store.hasPending("f1", item(1).sortKey), "the row shows the queued mark")
        }

    @Test
    fun `the queue keeps the latest change for an item and slot, and a remove stays a remove`() =
        runTest {
            val store = store(item(1), item(2))

            store.setFlag("f1", item(1).sortKey, later, true)
            store.setFlag("f1", item(1).sortKey, later, false)

            // Not nothing: another device may have set the flag, and the
            // server has to be told it is off.
            val row = store.flagRows().single()
            assertFalse(row.value, "the add then the remove leave a remove")
            assertEquals(emptySet<String>(), store.flagsOf(item(1)))

            store.setFlag("f1", item(1).sortKey, work, true)
            store.setFlag("f1", item(2).sortKey, later, true)
            store.setRead("f1", item(1).sortKey, true)
            store.setFavorite("f1", item(1).sortKey, true)

            assertEquals(
                listOf("i1 $later false", "i1 $work true", "i2 $later true"),
                store.flagRows().map { "${it.sortKey.substringAfter('#')} ${it.slot} ${it.value}" },
                "another slot, and another item, each keep their own row",
            )
            assertEquals(5, store.pendingCount(), "a read or favorite mark replaces no flag row, nor a flag row them")
        }

    @Test
    fun `an item arrives with the flags the server holds`() =
        runTest {
            val store = store(item(1, flags = setOf(work, later)))

            assertEquals(setOf(later, work), store.flagsOf(item(1)))
            assertEquals(0, store.pendingCount(), "the server's flags queue nothing")
        }

    @Test
    fun `server states are laid under the queued changes, slot by slot`() =
        runTest {
            val store = store(item(1, flags = setOf(urgent)), item(2, flags = setOf(urgent)))
            store.setFlag("f1", item(1).sortKey, later, true)
            store.setFlag("f1", item(1).sortKey, urgent, false)

            // The server answered before either change reached it, and
            // another device has set a third flag meanwhile.
            store.applyServerStates(listOf(state(item(1), setOf(urgent, work)), state(item(2), setOf(work))))

            assertEquals(
                setOf(later, work),
                store.flagsOf(item(1)),
                "queued add kept, queued remove kept, the rest taken",
            )
            assertEquals(
                setOf(work),
                store.flagsOf(item(2)),
                "an item with nothing queued takes the server's list whole",
            )
            assertEquals(2, store.pendingCount(), "applying states queues nothing and clears nothing")
        }

    @Test
    fun `a state row for an item this device does not have is skipped`() =
        runTest {
            val store = store(item(1))

            store.applyServerStates(listOf(state(item(9), setOf(later))))

            assertEquals(null, store.flagsOf(item(9)))
            assertEquals(emptySet<String>(), store.flagsOf(item(1)))
        }

    @Test
    fun `an item listed again keeps only the slots with a queued change`() =
        runTest {
            val store = store(item(1, flags = setOf(urgent, work)))
            store.setFlag("f1", item(1).sortKey, later, true)
            store.setFlag("f1", item(1).sortKey, urgent, false)

            // Another device took `work` off; this page predates both of
            // this device's changes.
            store.upsertItems(listOf(item(1, flags = setOf(urgent))))

            assertEquals(setOf(later), store.flagsOf(item(1)))
        }

    @Test
    fun `a queued read mark does not hold the item's flags back`() =
        runTest {
            val store = store(item(1))
            store.setRead("f1", item(1).sortKey, true)

            store.upsertItems(listOf(item(1, flags = setOf(work))))

            assertEquals(setOf(work), store.flagsOf(item(1)), "the read mark shields read and favorite, not the flags")
            assertTrue(store.item("f1", item(1).sortKey)!!.isRead)
        }

    @Test
    fun `a refused add leaves the queue and its flag leaves the item`() =
        runTest {
            val store = store(item(1, flags = setOf(urgent)), item(2))
            store.setFlag("f1", item(1).sortKey, later, true)
            store.setFlag("f1", item(1).sortKey, urgent, false)
            store.setFlag("f1", item(2).sortKey, later, true)
            store.setRead("f1", item(2).sortKey, true)
            val ids = store.pendingMutations().map { it.id }

            val dropped = store.dropRefusedFlagAdds(ids)

            assertEquals(2, dropped, "the two adds, and neither the remove nor the read mark")
            assertEquals(emptySet<String>(), store.flagsOf(item(1)))
            assertEquals(emptySet<String>(), store.flagsOf(item(2)))
            assertEquals(
                listOf(PendingKind.FLAG to false, PendingKind.READ to true),
                store.pendingMutations().map { it.kind to it.value },
            )
        }

    @Test
    fun `a refused add the user has changed again since is left alone`() =
        runTest {
            val store = store(item(1))
            store.setFlag("f1", item(1).sortKey, later, true)
            val read = store.pendingMutations().map { it.id }
            // Off and on again while the refusal was on its way back: a new
            // row, which the drain that was refused never read.
            store.setFlag("f1", item(1).sortKey, later, false)
            store.setFlag("f1", item(1).sortKey, later, true)

            assertEquals(0, store.dropRefusedFlagAdds(read))

            assertEquals(setOf(later), store.flagsOf(item(1)))
            assertEquals(1, store.flagRows().size)
        }

    @Test
    fun `leaving a feed takes its queued flag changes with it`() =
        runTest {
            val store = store(item(1))
            store.setFlag("f1", item(1).sortKey, later, true)

            store.replaceCatalog(
                com.cabalmail.kit.models
                    .RssCatalog(),
            )

            assertEquals(0, store.pendingCount())
        }

    @Test
    fun `stored flags are a sorted list, and anything else reads as none`() {
        assertEquals("""["$later","$urgent"]""", RssStoredFlags.encode(setOf(urgent, later)))
        assertEquals(RssStoredFlags.NONE, RssStoredFlags.encode(emptySet()))
        assertEquals(setOf(later, urgent), RssStoredFlags.decode("""["$urgent","$later"]"""))
        assertEquals(emptySet<String>(), RssStoredFlags.decode(""))
        assertEquals(emptySet<String>(), RssStoredFlags.decode("""{"a":1}"""))
    }
}
