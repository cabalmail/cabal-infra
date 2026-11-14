package com.cabalmail.kit.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/**
 * A device sends only what was changed on it, and says which version of
 * the account's row it was built on. Before, every push carried the whole
 * payload at this device's values, the display name with it, so a device
 * that had never read the row (#2452), or had not seen another device's
 * change (#2464), put its own copy over the account's; and the store was
 * one per device, so the next account signed in inherited the last
 * one's settings (#2471). These are those issues' steps, against
 * [FakeSettingsServer] behind a real API client and a real DataStore file.
 */
class PreferencesRepositorySyncTest {
    @TempDir
    lateinit var directory: File

    private val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    // Never run: the repository's debounced push would otherwise fire in
    // the middle of a test. Each test sends by hand (`pushToServer`).
    private val idleScope = CoroutineScope(SupervisorJob() + StandardTestDispatcher())

    private val server = FakeSettingsServer()
    private var signedIn: String? = "alice@cabalmail.example"

    private val store: DataStore<Preferences> by lazy {
        PreferenceDataStoreFactory.create(scope = storeScope) { File(directory, "settings.preferences_pb") }
    }

    @AfterEach
    fun tearDown() {
        storeScope.cancel()
        idleScope.cancel()
    }

    /** A repository over the one store: a second call is a relaunch. */
    private fun launch() = PreferencesRepository(store, idleScope, account = { signedIn }) { server.api }

    private val urgent = FlagPaletteEntry(slot = "cabal-flag-02", label = "Urgent", color = "red")
    private val later = FlagPaletteEntry(slot = "cabal-flag-01", label = "Later", color = "blue")

    /** An account another device has set up. */
    private fun accountsSettings() {
        server.anotherDeviceWrites(
            app =
                mapOf(
                    "signature" to "The account's signature",
                    "default_from_address" to "me@mail.cabalmail.example",
                    "mark_as_read" to "on_open",
                    "dispose_action" to "trash",
                    "theme" to "dark",
                    "flag_palette" to FlagPalette.encode(listOf(urgent)),
                ),
            flat = mapOf("name" to "Alice", "accent" to "plum"),
        )
    }

    private fun appOf(write: Int) =
        server.writes[write]["app"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content }

    private fun labelsOnTheServer() = FlagPalette.decode(server.app.getValue("flag_palette"))?.map { it.label }

    // ------------------------------------------------- #2452: a new device

    @Test
    fun `a device new to the account never sends its defaults`() =
        runTest {
            accountsSettings()
            val onTheServer = server.app.toMap() to server.flat.toMap()
            server.failing += "get_preferences"
            val repository = launch()
            repository.refreshFromServer()

            // A folder's Unread pill, tapped before any pull has succeeded.
            repository.update { it.copy(mailFolderFilters = mapOf("INBOX" to MailFolderFilter.UNREAD)) }
            repository.pushToServer()

            assertEquals(emptyList<Any>(), server.writes, "nothing goes before the row is read")
            assertTrue(repository.hasUnsentChanges(), "the tap is not lost")

            server.failing.clear()
            repository.refreshFromServer()

            assertEquals(1, server.writes.size)
            assertEquals(mapOf("filter:mail:INBOX" to "unread"), appOf(0))
            assertEquals(setOf("app", "expectedVersion"), server.writes[0].keys, "no display name, accent or theme")
            assertEquals(onTheServer.first + ("filter:mail:INBOX" to "unread"), server.app)
            assertEquals(onTheServer.second, server.flat)
            val now = repository.current()
            assertEquals("The account's signature", now.signature)
            assertEquals("me@mail.cabalmail.example", now.defaultFromAddress)
            assertEquals("Alice", now.displayName)
            assertEquals(Accent.PLUM, now.accent)
            assertEquals(MailFolderFilter.UNREAD, now.mailFolderFilters["INBOX"])
            assertFalse(repository.hasUnsentChanges())
        }

    // ------------------------------------- #2464: a device that is behind

    @Test
    fun `a device that has not seen another device's change does not put its older settings back`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            server.anotherDeviceWrites(
                app =
                    mapOf(
                        "flag_palette" to FlagPalette.encode(listOf(urgent.copy(label = "XD"))),
                        "signature" to "Changed on A",
                    ),
                flat = mapOf("name" to "Alice A."),
            )

            repository.update { it.copy(mailFolderFilters = mapOf("INBOX" to MailFolderFilter.UNREAD)) }
            repository.pushToServer()

            assertEquals(listOf("XD"), labelsOnTheServer(), "A's rename stands")
            assertEquals("Changed on A", server.app["signature"])
            assertEquals("Alice A.", server.flat["name"])
            assertEquals("unread", server.app["filter:mail:INBOX"])
            // The server refused the push built on the older row, this
            // device took the row it was answered with, and sent again.
            assertEquals(listOf("set_preferences stale", "set_preferences ok"), server.calls.takeLast(2))
            assertEquals(mapOf("filter:mail:INBOX" to "unread"), appOf(0))
            assertEquals(mapOf("filter:mail:INBOX" to "unread"), appOf(1))
            assertEquals(listOf<Int?>(1, 2), server.writeVersions)
            // And it has A's changes without waiting for its next launch.
            val now = repository.current()
            assertEquals(listOf("XD"), now.flagPalette.map { it.label })
            assertEquals("Changed on A", now.signature)
            assertEquals("Alice A.", now.displayName)
        }

    @Test
    fun `both devices edit the flag list and both edits survive`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            val addedOnA = FlagPaletteEntry(slot = "cabal-flag-03", label = "Added on A", color = "teal")
            server.anotherDeviceWrites(app = mapOf("flag_palette" to FlagPalette.encode(listOf(urgent, addedOnA))))

            repository.update { it.copy(flagPalette = it.flagPalette + later) }
            repository.pushToServer()

            assertEquals(listOf("Urgent", "Added on A", "Later"), labelsOnTheServer())
            assertEquals(listOf("Urgent", "Added on A", "Later"), repository.current().flagPalette.map { it.label })
            assertFalse(repository.hasUnsentChanges())
        }

    @Test
    fun `each device adds a flag and the server ends with both`() =
        runTest {
            // Both apps give a new flag the first free slot, so the two
            // arrive on the same one.
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            val slot = FlagPalette.firstFreeSlot(repository.current().flagPalette)!!
            val addedOnA = FlagPaletteEntry(slot = slot, label = "Added on A", color = "teal")
            server.anotherDeviceWrites(app = mapOf("flag_palette" to FlagPalette.encode(listOf(urgent, addedOnA))))

            repository.update { it.copy(flagPalette = it.flagPalette + FlagPaletteEntry(slot, "New flag", "red")) }
            repository.pushToServer()

            assertEquals(listOf("Urgent", "Added on A", "New flag"), labelsOnTheServer())
            assertEquals(
                listOf("cabal-flag-02", "cabal-flag-01", "cabal-flag-03"),
                repository.current().flagPalette.map { it.slot },
            )
        }

    @Test
    fun `a push gives up when the row keeps moving, and the change waits`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            server.keepsMovingOn = true

            repository.update { it.copy(signature = "Mine") }
            repository.pushToServer()

            assertEquals(List(4) { "set_preferences stale" }, server.calls.takeLast(4))
            assertTrue(repository.hasUnsentChanges())
            assertEquals("Mine", repository.current().signature)
        }

    // --------------------------------------------- what a push carries

    @Test
    fun `the display name goes by itself, and only when it was changed`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()

            repository.update { it.copy(displayName = "Alice B.") }
            repository.pushToServer()
            repository.update { it.copy(signature = "Cheers") }
            repository.pushToServer()

            assertEquals(setOf("name", "expectedVersion"), server.writes[0].keys)
            assertEquals(setOf("app", "expectedVersion"), server.writes[1].keys)
            assertEquals(mapOf("signature" to "Cheers"), appOf(1))
            assertEquals("Alice B.", server.flat["name"])
        }

    @Test
    fun `a setting put back to what the server holds sends nothing`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            server.failing += "set_preferences"
            repository.update { it.copy(disposeAction = DisposeAction.ARCHIVE) }
            repository.pushToServer()
            assertTrue(repository.hasUnsentChanges())

            repository.update { it.copy(disposeAction = DisposeAction.TRASH) }
            server.failing.clear()
            repository.pushToServer()

            assertFalse(repository.hasUnsentChanges())
            assertEquals(emptyList<Any>(), server.writes)
        }

    @Test
    fun `a change that could not be sent goes at the next launch, and the pull leaves it`() =
        runTest {
            accountsSettings()
            val first = launch()
            first.refreshFromServer()
            server.failing += "set_preferences"
            first.update { it.copy(flagPalette = it.flagPalette + later) }
            first.pushToServer()
            server.failing.clear()
            server.anotherDeviceWrites(app = mapOf("signature" to "Changed elsewhere"))

            val relaunched = launch()
            assertTrue(relaunched.hasUnsentChanges())
            relaunched.refreshFromServer()

            assertEquals(listOf("Urgent", "Later"), labelsOnTheServer())
            assertEquals("Changed elsewhere", relaunched.current().signature, "the pull was not held")
            assertEquals("Changed elsewhere", server.app["signature"])
            assertFalse(relaunched.hasUnsentChanges())
        }

    @Test
    fun `a refused change is not sent again until it changes`() =
        runTest {
            val repository = launch()
            repository.refreshFromServer()
            server.refuseNext = true
            repository.update { it.copy(signature = "One") }
            repository.pushToServer()
            repository.pushToServer()
            repository.refreshFromServer()

            assertEquals(1, server.writes.size, "the same change is not sent a second time")
            assertTrue(repository.hasUnsentChanges())

            repository.update { it.copy(signature = "Two") }
            repository.pushToServer()

            assertEquals("Two", server.app["signature"])
            assertFalse(repository.hasUnsentChanges())
        }

    @Test
    fun `the system theme is not overridden by the web theme while it is owed`() =
        runTest {
            accountsSettings()
            server.anotherDeviceWrites(flat = mapOf("theme" to "dark"))
            val repository = launch()
            repository.refreshFromServer()
            assertEquals(AppTheme.DARK, repository.current().theme)
            server.failing += "set_preferences"

            repository.update { it.copy(theme = AppTheme.SYSTEM) }
            repository.pushToServer()
            server.failing.clear()
            repository.refreshFromServer()

            assertEquals(AppTheme.SYSTEM, repository.current().theme)
            assertEquals("system", server.app["theme"])
            assertEquals("dark", server.flat["theme"], "the web keeps its own theme")
        }

    // ------------------------------------------ a server from before

    @Test
    fun `an older server still gets only the changed key, and no version`() =
        runTest {
            server.predatesVersion = true
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()

            repository.update { it.copy(signature = "Mine") }
            repository.pushToServer()

            assertEquals(1, server.writes.size)
            assertEquals(setOf("app"), server.writes[0].keys)
            assertEquals(mapOf("signature" to "Mine"), appOf(0))
            assertFalse(repository.hasUnsentChanges())
        }

    // ------------------------------------------- #2471: another account

    @Test
    fun `another account signing in does not inherit the last account's settings`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            server.failing += "set_preferences"
            repository.update {
                it.copy(
                    signature = "Alice's unsent signature",
                    mailFolderFilters = mapOf("Alice/Private" to MailFolderFilter.UNREAD),
                    dynamicColor = false,
                )
            }
            repository.pushToServer()
            server.failing.clear()

            // Sign-out, then another account, whose row holds next to nothing.
            signedIn = "bob@cabalmail.example"
            server.app.clear()
            server.flat += mapOf("name" to "", "accent" to "forest")
            server.app["signature"] = "Bob's"
            val writesBefore = server.writes.size
            repository.refreshFromServer()
            repository.update { it.copy(markAsRead = MarkAsRead.ON_OPEN) }
            repository.pushToServer()

            val now = repository.current()
            assertEquals("Bob's", now.signature)
            assertEquals(emptyList<FlagPaletteEntry>(), now.flagPalette, "not Alice's flags")
            assertEquals(emptyMap<String, MailFolderFilter>(), now.mailFolderFilters, "not Alice's folders")
            assertNull(now.defaultFromAddress)
            assertEquals("", now.displayName)
            assertFalse(now.dynamicColor, "a device setting stays the device's")
            assertEquals(1, server.writes.size - writesBefore)
            assertEquals(mapOf("mark_as_read" to "on_open"), appOf(server.writes.size - 1))
            assertEquals(mapOf("signature" to "Bob's", "mark_as_read" to "on_open"), server.app)
        }

    @Test
    fun `the same account signing in again keeps its settings and what it owes`() =
        runTest {
            accountsSettings()
            val repository = launch()
            repository.refreshFromServer()
            server.failing += "set_preferences"
            repository.update { it.copy(signature = "Unsent") }
            repository.pushToServer()
            server.failing.clear()

            signedIn = null
            repository.update { it.copy(dynamicColor = false) }
            signedIn = "Alice@Cabalmail.example"
            repository.refreshFromServer()

            assertEquals("Unsent", server.app["signature"])
            assertEquals(listOf("Urgent"), repository.current().flagPalette.map { it.label })
        }
}
