package com.cabalmail.kit.rss

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.settings.FlagPalette
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.IOException

/**
 * Flags of the user's own on feed items, through [RssSyncEngine] against
 * [FakeRssServer], which holds state rows and a flag list as the server
 * does: what the drain sends, what it does when the server refuses a flag
 * it adds, and how two devices' changes to one item meet
 * (`docs/1.x/cross-media-ux-plan.md`, Phase 2b).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RssFlagSyncTest {
    private val later = "cabal-flag-01"
    private val work = "cabal-flag-02"
    private val urgent = "cabal-flag-03"
    private val sub = RssSubscription(subscriptionId = "s1", feedId = "f1")

    private fun item(n: Int) =
        RssItem(
            feedId = "f1",
            sortKey = "2026-01-01T10:00:00+00:00#i${n.toString().padStart(3, '0')}",
            itemId = "i$n",
            publishedAt = "2026-01-01T10:00:00+00:00",
        )

    /** A device: its own store over the one server, holding [items]. */
    private suspend fun device(
        server: FakeRssServer,
        vararg items: RssItem,
    ): RssSyncEngine =
        RssSyncEngine(server, InMemoryRssStore()).also {
            it.store.upsertSubscription(sub)
            it.store.upsertItems(items.toList())
        }

    private suspend fun RssSyncEngine.flagsOf(item: RssItem) = store.item(item.feedId, item.sortKey)?.flags

    private fun FakeRssServer.offline() {
        failure = IOException("unreachable")
    }

    private fun FakeRssServer.online() {
        failure = null
    }

    // ------------------------------------------------------------ the drain

    @Test
    fun `a flag set and then cleared goes as an add and then a remove`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))

            phone.setFlag(item(1), later, true)

            assertEquals(setOf(later), server.flagsOf(item(1)))
            assertEquals(listOf(RssItemStateChange("f1", item(1).sortKey, addFlags = setOf(later))), server.calls[0])
            assertEquals(0, phone.store.pendingCount())

            phone.setFlag(item(1), later, false)

            assertEquals(emptySet<String>(), server.flagsOf(item(1)))
            assertEquals(listOf(RssItemStateChange("f1", item(1).sortKey, removeFlags = setOf(later))), server.calls[1])
            assertEquals(emptySet<String>(), phone.flagsOf(item(1)))
        }

    @Test
    fun `only a keyword slot is taken, and the built-in flag is not one`() =
        runTest {
            val server = FakeRssServer()
            val phone = device(server, item(1))

            for (slot in listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-21", "cabal-flag-00", "", "Later")) {
                assertThrows<IllegalArgumentException> { phone.setFlag(item(1), slot, true) }
            }

            assertEquals(0, phone.store.pendingCount(), "nothing the server would refuse for good is ever queued")
            assertEquals(emptyList<Any>(), server.calls)
        }

    @Test
    fun `every queued change to one item is one entry`() =
        runTest {
            val server = FakeRssServer().apply { palette += listOf(later, work) }
            val phone = device(server, item(1), item(2))
            server.offline()
            phone.setFlag(item(1), later, true)
            phone.setFlag(item(1), urgent, false)
            phone.setFlag(item(1), work, true)
            phone.setRead(item(1), true)
            phone.setFavorite(item(1), true)
            phone.setFlag(item(2), later, false)
            server.calls.clear()
            server.online()

            assertEquals(6, phone.drainPending())

            assertEquals(
                listOf(
                    RssItemStateChange(
                        "f1",
                        item(1).sortKey,
                        isRead = true,
                        isFavorite = true,
                        addFlags = setOf(later, work),
                        removeFlags = setOf(urgent),
                    ),
                    RssItemStateChange("f1", item(2).sortKey, removeFlags = setOf(later)),
                ),
                server.calls.single(),
            )
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `a slot never goes in both lists of an entry`() {
        fun row(
            id: Long,
            value: Boolean,
        ) = PendingMutation(id, PendingKind.FLAG, "f1", "k", subscriptionId = "", value = value, slot = later)

        // The queue holds one row per item and slot; were there two, the
        // later one is the intent.
        assertEquals(
            listOf(RssItemStateChange("f1", "k", removeFlags = setOf(later))),
            RssSyncEngine.stateChanges(listOf(row(1, true), row(2, false))),
        )
        assertEquals(
            listOf(RssItemStateChange("f1", "k", addFlags = setOf(later))),
            RssSyncEngine.stateChanges(listOf(row(1, false), row(2, true))),
        )
    }

    @Test
    fun `a hundred and fifty items go as two calls`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val items = (1..150).map { item(it) }
            val phone = device(server, *items.toTypedArray())
            server.offline()
            items.forEach { phone.setFlag(it, later, true) }
            server.calls.clear()
            server.online()

            assertEquals(150, phone.drainPending())

            assertEquals(listOf(100, 50), server.calls.map { it.size })
            assertEquals(150, server.rows.values.count { later in it.flags })
        }

    @Test
    fun `a failed push leaves the flag queued and on its item`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))
            server.offline()

            phone.setFlag(item(1), later, true)

            assertEquals(setOf(later), phone.flagsOf(item(1)))
            assertEquals(1, phone.store.pendingCount())

            server.online()
            assertEquals(1, phone.drainPending())
            assertEquals(setOf(later), server.flagsOf(item(1)))
        }

    @Test
    fun `drains go one at a time, so a clear made during an add's push lands after it`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))
            val parked = CompletableDeferred<Unit>()
            server.gate = parked

            val adding = launch { phone.setFlag(item(1), later, true) }
            server.gateReached.await()
            // The add is at the server and has not been written. The user
            // clears the flag; that change's own drain must not overtake it.
            val clearing = launch { phone.setFlag(item(1), later, false) }
            runCurrent()

            assertEquals(1, server.calls.size, "the clear waits for the add's drain")

            parked.complete(Unit)
            adding.join()
            clearing.join()

            assertEquals(
                listOf(setOf(later) to emptySet(), emptySet<String>() to setOf(later)),
                server.calls.map { it.single().addFlags to it.single().removeFlags },
            )
            assertEquals(emptySet<String>(), server.flagsOf(item(1)), "the later intent is what the server holds")
            assertEquals(emptySet<String>(), phone.flagsOf(item(1)))
            assertEquals(0, phone.store.pendingCount())
        }

    // ---------------------------------------------------------- two devices

    @Test
    fun `two devices offline each add a flag to one item, and it carries both`() =
        runTest {
            val server = FakeRssServer().apply { palette += listOf(urgent, "cabal-flag-05") }
            val phone = device(server, item(1))
            val tablet = device(server, item(1))
            server.offline()
            phone.setFlag(item(1), urgent, true)
            tablet.setFlag(item(1), "cabal-flag-05", true)
            server.online()

            phone.syncItems(sub)
            phone.drainPending()
            tablet.syncItems(sub)
            tablet.drainPending()
            phone.syncItems(sub)
            tablet.syncItems(sub)

            val both = setOf(urgent, "cabal-flag-05")
            assertEquals(both, server.flagsOf(item(1)))
            assertEquals(both, phone.flagsOf(item(1)))
            assertEquals(both, tablet.flagsOf(item(1)))
        }

    @Test
    fun `a state sync ahead of the drain does not take a queued flag off`() =
        runTest {
            val server = FakeRssServer().apply { palette += listOf(later, work) }
            val phone = device(server, item(1))
            val tablet = device(server, item(1))
            tablet.setFlag(item(1), work, true)
            server.offline()
            phone.setFlag(item(1), later, true)
            server.online()

            // The server's row for the item has `work` and not `later`.
            phone.syncItems(sub)

            assertEquals(setOf(later, work), phone.flagsOf(item(1)))
            assertEquals(1, phone.store.pendingCount())

            phone.drainPending()
            assertEquals(setOf(later, work), server.flagsOf(item(1)))
        }

    @Test
    fun `a flag cleared on another device leaves this one at its next sync`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))
            val tablet = device(server, item(1))
            phone.setFlag(item(1), later, true)
            tablet.syncItems(sub)
            assertEquals(setOf(later), tablet.flagsOf(item(1)))

            phone.setFlag(item(1), later, false)
            tablet.syncItems(sub)

            assertEquals(emptySet<String>(), tablet.flagsOf(item(1)))
        }

    // ------------------------------------------------------- a refused add

    /** [phone] with [later] added to items 1 and 2 and a read mark on 2, all queued; the server holds no flag. */
    private suspend fun queuedAgainstAnEmptyPalette(server: FakeRssServer): RssSyncEngine {
        val phone = device(server, item(1), item(2))
        server.offline()
        phone.setFlag(item(1), later, true)
        phone.setFlag(item(2), later, true)
        phone.setRead(item(2), true)
        server.calls.clear()
        server.outcomes.clear()
        server.online()
        return phone
    }

    @Test
    fun `refused with nothing unsent, the adds are dropped and the rest of the batch goes`() =
        runTest {
            val server = FakeRssServer()
            val phone = queuedAgainstAnEmptyPalette(server)
            var asked = 0
            phone.unsentSettingsPush = {
                asked += 1
                RssUnsentSettings.NOTHING_UNSENT
            }

            assertEquals(3, phone.drainPending(), "every row left the queue")

            assertEquals(1, asked)
            assertEquals(listOf("refused", "ok"), server.outcomes)
            assertEquals(listOf(RssItemStateChange("f1", item(2).sortKey, isRead = true)), server.calls[1])
            assertEquals(emptySet<String>(), phone.flagsOf(item(1)), "the flag is taken off the item again")
            assertEquals(emptySet<String>(), phone.flagsOf(item(2)))
            assertEquals(0, phone.store.pendingCount())
            assertTrue(server.rows.getValue(item(2).id).isRead, "the mark behind the refusal went")
        }

    @Test
    fun `with nobody to ask, a refused add is dropped`() =
        runTest {
            val server = FakeRssServer()
            val phone = queuedAgainstAnEmptyPalette(server)

            assertEquals(3, phone.drainPending())

            assertEquals(emptySet<String>(), phone.flagsOf(item(1)))
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `refused while the flag list is unsent, the list is sent and the batch goes again as it was`() =
        runTest {
            val server = FakeRssServer()
            val phone = queuedAgainstAnEmptyPalette(server)
            var asked = 0
            phone.unsentSettingsPush = {
                asked += 1
                // The settings push that carries the new flag lands.
                server.palette += later
                RssUnsentSettings.SENT
            }

            assertEquals(3, phone.drainPending())

            assertEquals(1, asked)
            assertEquals(listOf("refused", "ok"), server.outcomes)
            assertEquals(server.calls[0], server.calls[1], "the same batch")
            assertEquals(setOf(later), server.flagsOf(item(1)))
            assertEquals(setOf(later), phone.flagsOf(item(1)), "the flag stays on the item")
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `a refusal after the settings went is final, and nobody is asked twice`() =
        runTest {
            val server = FakeRssServer()
            val phone = queuedAgainstAnEmptyPalette(server)
            var asked = 0
            phone.unsentSettingsPush = {
                asked += 1
                // Something was sent, but the flag was deleted on another
                // device: the server's list still does not hold it.
                RssUnsentSettings.SENT
            }

            assertEquals(3, phone.drainPending())

            assertEquals(1, asked, "asking again after every \"sent\" would never end")
            assertEquals(listOf("refused", "refused", "ok"), server.outcomes)
            assertEquals(emptySet<String>(), phone.flagsOf(item(1)))
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `refused while the flag list cannot be sent, the adds wait and the rest of the batch goes`() =
        runTest {
            val server = FakeRssServer()
            val phone = queuedAgainstAnEmptyPalette(server)
            phone.unsentSettingsPush = { RssUnsentSettings.STILL_UNSENT }

            assertEquals(1, phone.drainPending(), "only the read mark left the queue")

            assertEquals(listOf("refused", "ok"), server.outcomes)
            assertEquals(setOf(later), phone.flagsOf(item(1)), "the flag stays on its item")
            assertEquals(setOf(later), phone.flagsOf(item(2)))
            assertEquals(
                listOf(PendingKind.FLAG, PendingKind.FLAG),
                phone.store.pendingMutations().map { it.kind },
            )
            assertTrue(server.rows.getValue(item(2).id).isRead)

            // Later the settings go, and the next drain sends the adds.
            server.palette += later
            phone.unsentSettingsPush = { RssUnsentSettings.NOTHING_UNSENT }
            assertEquals(2, phone.drainPending())
            assertEquals(setOf(later), server.flagsOf(item(1)))
            assertEquals(setOf(later), phone.flagsOf(item(1)))
        }

    @Test
    fun `only the refused slot's adds are dropped`() =
        runTest {
            val server = FakeRssServer().apply { palette += work }
            val phone = device(server, item(1))
            server.offline()
            phone.setFlag(item(1), later, true)
            phone.setFlag(item(1), work, true)
            phone.setFlag(item(1), urgent, false)
            server.online()

            assertEquals(3, phone.drainPending())

            assertEquals(setOf(work), phone.flagsOf(item(1)))
            assertEquals(setOf(work), server.flagsOf(item(1)))
            assertEquals(
                RssItemStateChange("f1", item(1).sortKey, addFlags = setOf(work), removeFlags = setOf(urgent)),
                server.calls.last().single(),
            )
        }

    @Test
    fun `a remove of the refused slot on another item still goes with the rest of the batch`() =
        runTest {
            val server = FakeRssServer()
            val phone = device(server, item(1), item(2))
            server.offline()
            phone.setFlag(item(1), later, true)
            phone.setFlag(item(2), later, false)
            server.calls.clear()
            server.online()

            assertEquals(2, phone.drainPending())

            assertEquals(
                listOf(RssItemStateChange("f1", item(2).sortKey, removeFlags = setOf(later))),
                server.calls.last(),
                "the refusal is about the add; a remove of that slot is always allowed",
            )
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `the palette's own slot writes the favorite mark, and any other a flag`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))

            phone.setPaletteFlag(item(1), FlagPalette.SYSTEM_SLOT, true)
            phone.setPaletteFlag(item(1), later, true)

            val stored = phone.store.item("f1", item(1).sortKey)!!
            assertTrue(stored.isFavorite)
            assertEquals(setOf(later), stored.flags)
            assertEquals(listOf(FlagPalette.SYSTEM_SLOT, later), stored.paletteFlags)
            assertTrue(server.rows.getValue(item(1).id).isFavorite)
            assertEquals(setOf(later), server.flagsOf(item(1)))

            phone.setPaletteFlag(item(1), FlagPalette.SYSTEM_SLOT, false)
            assertFalse(phone.store.item("f1", item(1).sortKey)!!.isFavorite)
            assertEquals(setOf(later), phone.flagsOf(item(1)), "clearing one leaves the other")
        }

    @Test
    fun `an item's flags read and change by palette slot, the built-in flag's included`() {
        val plain = item(1)
        val flagged = plain.withFlag(FlagPalette.SYSTEM_SLOT, true).withFlag(work, true).withFlag(later, true)

        assertTrue(flagged.isFavorite)
        assertEquals(setOf(later, work), flagged.flags)
        assertEquals(listOf(FlagPalette.SYSTEM_SLOT, later, work), flagged.paletteFlags)
        assertEquals(listOf(later, work), flagged.copy(isFavorite = false).paletteFlags)
        assertTrue(flagged.carries(FlagPalette.SYSTEM_SLOT) && flagged.carries(work))
        assertFalse(plain.carries(FlagPalette.SYSTEM_SLOT) || plain.carries(work))
        assertEquals(
            plain.copy(flags = setOf(later)),
            flagged.withFlag(FlagPalette.SYSTEM_SLOT, false).withFlag(work, false),
        )
        assertEquals(emptyList<String>(), plain.paletteFlags)
    }

    @Test
    fun `a remove of a flag the server does not hold is never refused or dropped`() =
        runTest {
            val server = FakeRssServer()
            val phone = device(server, item(1))

            phone.setFlag(item(1), later, false)

            assertEquals(listOf("ok"), server.outcomes)
            assertEquals(0, phone.store.pendingCount())
        }

    @Test
    fun `a refusal naming no slot this batch adds leaves the queue as any failure does`() =
        runTest {
            val server = FakeRssServer().apply { palette += later }
            val phone = device(server, item(1))
            server.failure = RssFlagRefusal(setOf(urgent), "Not a flag in the palette: $urgent.")
            var asked = 0
            phone.unsentSettingsPush = {
                asked += 1
                RssUnsentSettings.NOTHING_UNSENT
            }
            phone.setFlag(item(1), later, true)

            val thrown = assertThrows<CabalmailException.ApiError> { phone.drainPending() }

            assertEquals(RssFlagRefusal.CODE, thrown.code)
            assertEquals(listOf(urgent), thrown.flags)
            assertEquals(0, asked)
            assertEquals(1, phone.store.pendingCount())
            assertEquals(setOf(later), phone.flagsOf(item(1)))
        }

    @Test
    fun `a refused add in one call does not hold the calls after it`() =
        runTest {
            val server = FakeRssServer().apply { palette += work }
            val items = (1..120).map { item(it) }
            val phone = device(server, *items.toTypedArray())
            server.offline()
            phone.setFlag(items[0], later, true)
            items.drop(1).forEach { phone.setFlag(it, work, true) }
            server.calls.clear()
            server.outcomes.clear()
            server.online()

            assertEquals(120, phone.drainPending())

            assertEquals(listOf("refused", "ok", "ok"), server.outcomes)
            assertFalse(later in phone.flagsOf(items[0]).orEmpty())
            assertEquals(119, server.rows.values.count { work in it.flags })
        }
}
