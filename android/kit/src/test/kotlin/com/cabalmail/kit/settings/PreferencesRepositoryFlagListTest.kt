package com.cabalmail.kit.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.rss.FakeRssServer
import com.cabalmail.kit.rss.InMemoryRssStore
import com.cabalmail.kit.rss.RssSyncEngine
import com.cabalmail.kit.rss.RssUnsentSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/**
 * What the feed queue is told when it asks for the flag list this device
 * owes the server to be sent ([PreferencesRepository.sendOwedFlagList]),
 * and the case that asks: a flag created while the settings could not be
 * sent, put on a feed item, and refused by a server that has not heard of
 * it (the Android twin of #2421). Against [FakeSettingsServer] behind a
 * real API client, a real DataStore file, and a [FakeRssServer] that reads
 * its flag list from the same row.
 */
class PreferencesRepositoryFlagListTest {
    @TempDir
    lateinit var directory: File

    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    // Never run: each test sends by hand, as the settings sync tests do.
    private val idleScope = CoroutineScope(SupervisorJob() + StandardTestDispatcher())

    private val server = FakeSettingsServer()

    private val store: DataStore<Preferences> by lazy {
        PreferenceDataStoreFactory.create(scope = storeScope) { File(directory, "settings.preferences_pb") }
    }

    @AfterEach
    fun tearDown() {
        storeScope.cancel()
        idleScope.cancel()
    }

    private fun launch() =
        PreferencesRepository(store, idleScope, account = { "alice@cabalmail.example" }) { server.api }

    private val later = FlagPaletteEntry(slot = "cabal-flag-01", label = "Later", color = "blue")

    private fun slotsOnTheServer(): Set<String> =
        server.app["flag_palette"]
            ?.let(FlagPalette::decode)
            .orEmpty()
            .map { it.slot }
            .toSet()

    private fun writes() = server.calls.count { it.startsWith("set_preferences") }

    @Test
    fun `with no change to the flag list owed, nothing is sent and the answer says so`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            // Something else is owed, and cannot be sent.
            server.failing += "set_preferences"
            repository.update { it.copy(signature = "Regards") }
            repository.pushToServer()
            val before = server.calls.size

            assertEquals(RssUnsentSettings.NOTHING_UNSENT, repository.sendOwedFlagList())

            assertEquals(before, server.calls.size, "a refused flag is not a reason to send anything else")
        }

    @Test
    fun `an owed flag list is sent, and the answer is that it went`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            server.failing += "set_preferences"
            repository.update { it.copy(flagPalette = listOf(later)) }
            repository.pushToServer()
            assertEquals(emptySet<String>(), slotsOnTheServer())
            server.failing.clear()

            assertEquals(RssUnsentSettings.SENT, repository.sendOwedFlagList())

            assertEquals(setOf(later.slot), slotsOnTheServer())
            assertFalse(repository.hasUnsentChanges())
        }

    @Test
    fun `an owed flag list that still cannot be sent is still unsent`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            server.failing += "set_preferences"
            repository.update { it.copy(flagPalette = listOf(later)) }

            assertEquals(RssUnsentSettings.STILL_UNSENT, repository.sendOwedFlagList())

            assertTrue(repository.hasUnsentChanges())
        }

    @Test
    fun `an owed flag list the server refuses is still unsent, and is not sent twice`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            server.refuseNext = true
            repository.update { it.copy(flagPalette = listOf(later)) }

            assertEquals(RssUnsentSettings.STILL_UNSENT, repository.sendOwedFlagList())
            val sent = writes()
            assertEquals(RssUnsentSettings.STILL_UNSENT, repository.sendOwedFlagList())

            assertEquals(sent, writes(), "a refused change waits for an edit, whoever asks")
        }

    @Test
    fun `a device that has not read the row reads it first, then sends the flag list`() =
        runTest {
            server.anotherDeviceWrites(app = mapOf("signature" to "The account's signature"))
            val repository = launch()
            repository.update { it.copy(flagPalette = listOf(later)) }

            assertEquals(RssUnsentSettings.SENT, repository.sendOwedFlagList())

            assertEquals(listOf("get_preferences ok", "set_preferences ok"), server.calls)
            assertEquals(setOf(later.slot), slotsOnTheServer())
            assertEquals("The account's signature", server.app["signature"], "and sends nothing it did not change")
        }

    // --------------------------------- the feed queue and a flag made offline

    private val item =
        RssItem(feedId = "f1", sortKey = "2026-01-01T10:00:00+00:00#i1", itemId = "i1", publishedAt = "2026-01-01")

    /** The feed queue of the same device, its server reading the flag list from the settings row. */
    private suspend fun feeds(repository: PreferencesRepository): Pair<RssSyncEngine, FakeRssServer> {
        val feedServer = FakeRssServer().apply { paletteSource = ::slotsOnTheServer }
        val engine = RssSyncEngine(feedServer, InMemoryRssStore())
        engine.store.upsertSubscription(RssSubscription(subscriptionId = "s1", feedId = "f1"))
        engine.store.upsertItems(listOf(item))
        // As the app wires it.
        engine.unsentSettingsPush = { repository.sendOwedFlagList() }
        return engine to feedServer
    }

    @Test
    fun `a flag created while the settings could not be sent stays on the feed item it was put on`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            val (engine, feedServer) = feeds(repository)
            // Offline: the flag is created in Settings and put on an item.
            server.failing += "set_preferences"
            feedServer.failure = java.io.IOException("unreachable")
            repository.update { it.copy(flagPalette = listOf(later)) }
            repository.pushToServer()
            engine.setFlag(item, later.slot, true)
            assertEquals(1, engine.store.pendingCount())
            // The connection is back, and the feed queue is first to the server.
            server.failing.clear()
            feedServer.failure = null
            feedServer.outcomes.clear()

            assertEquals(1, engine.drainPending())

            assertEquals(listOf("refused", "ok"), feedServer.outcomes, "refused, the settings sent, and the add again")
            assertEquals(setOf(later.slot), feedServer.flagsOf(item))
            assertEquals(setOf(later.slot), engine.store.item(item.feedId, item.sortKey)?.flags)
            assertEquals(0, engine.store.pendingCount())
            assertFalse(repository.hasUnsentChanges())
        }

    @Test
    fun `while the settings still cannot be sent the flag waits on its item, and goes once they can`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            val (engine, feedServer) = feeds(repository)
            server.failing += "set_preferences"
            repository.update { it.copy(flagPalette = listOf(later)) }

            // The feed API answers; the settings API does not.
            engine.setFlag(item, later.slot, true)

            assertEquals(listOf("refused"), feedServer.outcomes)
            assertEquals(setOf(later.slot), engine.store.item(item.feedId, item.sortKey)?.flags)
            assertEquals(1, engine.store.pendingCount())

            server.failing.clear()
            assertEquals(1, engine.drainPending())
            assertEquals(setOf(later.slot), feedServer.flagsOf(item))
        }

    @Test
    fun `a flag deleted before its add was sent is dropped, with nothing owed`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            repository.update { it.copy(flagPalette = listOf(later)) }
            repository.pushToServer()
            val (engine, feedServer) = feeds(repository)
            feedServer.failure = java.io.IOException("unreachable")
            engine.setFlag(item, later.slot, true)
            // Deleted in Settings, and the server told, before the queue drains.
            repository.update { it.copy(flagPalette = emptyList()) }
            repository.pushToServer()
            feedServer.failure = null

            assertEquals(1, engine.drainPending())

            assertEquals(emptySet<String>(), engine.store.item(item.feedId, item.sortKey)?.flags)
            assertEquals(0, engine.store.pendingCount())
            assertEquals(emptySet<String>(), feedServer.flagsOf(item))
        }
}
