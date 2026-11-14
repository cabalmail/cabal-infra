package com.cabalmail.kit.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/**
 * [PreferencesRepository] holds the typed settings to what the server
 * takes on the way into the store and on the way out of it (#2453).
 * Before, an emptied flag name, a signature over 2,000 code points or a
 * display name over 100 was stored as typed, and the server then refused
 * every settings request from the device, which carries them all.
 */
class PreferencesRepositoryTextRulesTest {
    @TempDir
    lateinit var directory: File

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @AfterEach
    fun tearDown() {
        scope.cancel()
    }

    private fun store(): DataStore<Preferences> =
        PreferenceDataStoreFactory.create(scope = scope) { File(directory, "settings.preferences_pb") }

    /** A repository with no server to reach: its pushes fail, and are swallowed. */
    private fun repository(store: DataStore<Preferences>) =
        PreferencesRepository(store, scope) { error("no server in this test") }

    @Test
    fun `a write stores the typed values as the server takes them`() =
        runTest {
            val repository = repository(store())

            repository.update {
                it.copy(
                    displayName = "  " + "n".repeat(150),
                    signature = "Regards\r\n".repeat(300),
                    flagPalette =
                        listOf(
                            FlagPaletteEntry(slot = "cabal-flag-01", label = "", color = "red"),
                            FlagPaletteEntry(slot = "cabal-flag-02", label = "Wor\u0007k", color = "blue"),
                        ),
                )
            }

            val stored = repository.current()
            assertEquals("n".repeat(100), stored.displayName)
            assertEquals(2000, stored.signature.codePointCount(0, stored.signature.length))
            assertEquals(listOf("New flag", "Work"), stored.flagPalette.map { it.label })
            // And what goes on the wire is what was stored.
            val update = PreferencesWire.toUpdate(stored)
            assertEquals("n".repeat(100), update.name)
            assertEquals(stored.signature, update.app?.get(PreferencesWire.AppKey.SIGNATURE))
            assertEquals(
                stored.flagPalette,
                update.app?.get(PreferencesWire.AppKey.FLAG_PALETTE)?.let(FlagPalette::decode),
            )
        }

    @Test
    fun `a value an older build stored is mended when it is read`() =
        runTest {
            val store = store()
            // As a build up to 1.53.0 left the store: an emptied name on
            // the first flag list the device ever tried to send.
            store.edit {
                it[stringPreferencesKey("flag_palette")] = """[{"slot":"cabal-flag-01","label":"","color":"red"}]"""
                it[stringPreferencesKey("signature")] = "s".repeat(2500)
                it[stringPreferencesKey("display_name")] = "n".repeat(120)
            }

            val read = repository(store).current()

            assertEquals(listOf("New flag"), read.flagPalette.map { it.label })
            assertEquals(2000, read.signature.length)
            assertEquals(100, read.displayName.length)
        }
}
