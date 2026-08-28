package com.cabalmail.kit.settings

import com.cabalmail.kit.models.Preferences
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Wire marshalling for the custom-flag palette (rules-composition plan,
 * Phase 3), the Kotlin sibling of the Apple kit's `FlagPaletteTests`,
 * plus the payload-inclusion rule that keeps an old server from 400ing
 * the whole preferences push.
 */
class FlagPaletteTest {
    private fun samplePalette() =
        listOf(
            FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red"),
            FlagPaletteEntry(slot = "cabal-flag-02", label = "Waiting", color = "blue", enabled = false),
        )

    @Test
    fun `encode decode round-trip`() {
        assertEquals(samplePalette(), FlagPalette.decode(FlagPalette.encode(samplePalette())))
    }

    @Test
    fun `enabled always rides the wire and defaults true on decode`() {
        val wire = FlagPalette.encode(listOf(FlagPaletteEntry("cabal-flag-01", "A", "red")))
        assertTrue("\"enabled\":true" in wire)

        val decoded = FlagPalette.decode("""[{"slot":"cabal-flag-03","label":"New","color":"chartreuse"}]""")!!
        assertTrue(decoded.single().enabled)
        // An unknown color (a newer server's vocabulary) is carried, not
        // coerced, and round-trips back out unchanged.
        assertEquals("chartreuse", decoded.single().color)
        assertTrue("chartreuse" in FlagPalette.encode(decoded))
    }

    @Test
    fun `garbage decodes to null`() {
        assertNull(FlagPalette.decode("not json"))
        assertNull(FlagPalette.decode("""{"slot":"x"}"""))
    }

    @Test
    fun `first free slot skips used and caps at twenty`() {
        assertEquals("cabal-flag-01", FlagPalette.firstFreeSlot(emptyList()))
        assertEquals("cabal-flag-03", FlagPalette.firstFreeSlot(samplePalette()))
        val full = FlagPalette.SLOTS.map { FlagPaletteEntry(it, "x", "red") }
        assertEquals(FlagPalette.MAX_ENTRIES, full.size)
        assertNull(FlagPalette.firstFreeSlot(full))
    }

    @Test
    fun `payload omits the palette until it is syncable`() {
        // A server that predates the key 400s the whole app map on it, so
        // an untouched palette must not ride the payload.
        assertFalse("flag_palette" in PreferencesWire.toUpdate(AppPreferences()).app!!.keys)

        // A palette with content rides...
        val withPalette = AppPreferences(flagPalette = samplePalette())
        assertEquals(
            FlagPalette.encode(samplePalette()),
            PreferencesWire.toUpdate(withPalette).app!!["flag_palette"],
        )

        // ...and once syncable, an emptied palette still rides so the
        // deletion can reach the server.
        val emptied = AppPreferences(flagPalette = emptyList(), flagPaletteSyncable = true)
        assertEquals("[]", PreferencesWire.toUpdate(emptied).app!!["flag_palette"])
    }

    @Test
    fun `remote palette applies and marks the key syncable`() {
        val remote =
            Preferences(app = mapOf("flag_palette" to FlagPalette.encode(samplePalette())))

        val applied = PreferencesWire.applyRemote(AppPreferences(), remote)

        assertEquals(samplePalette(), applied.flagPalette)
        assertTrue(applied.flagPaletteSyncable)
    }

    @Test
    fun `remote garbage leaves the palette untouched but proves the key`() {
        val current = AppPreferences(flagPalette = samplePalette())
        val applied =
            PreferencesWire.applyRemote(current, Preferences(app = mapOf("flag_palette" to "not json")))
        assertEquals(samplePalette(), applied.flagPalette)
        assertTrue(applied.flagPaletteSyncable)
    }

    @Test
    fun `an absent remote key leaves palette and syncable flag alone`() {
        val current = AppPreferences(flagPalette = samplePalette(), flagPaletteSyncable = true)
        val applied = PreferencesWire.applyRemote(current, Preferences(app = emptyMap()))
        assertEquals(samplePalette(), applied.flagPalette)
        assertTrue(applied.flagPaletteSyncable)
        assertFalse(PreferencesWire.applyRemote(AppPreferences(), Preferences()).flagPaletteSyncable)
    }
}
