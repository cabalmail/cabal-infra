package com.cabalmail.kit.settings

import com.cabalmail.kit.models.Preferences
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Wire marshalling for the flag palette (rules-composition plan, Phase 3),
 * the Kotlin sibling of the Apple kit's `FlagPaletteTests`, plus the
 * payload-inclusion rule that keeps an old server from 400ing the whole
 * preferences push, and the system flag's entry (unified-flags plan,
 * Phase 2).
 */
class FlagPaletteTest {
    private fun samplePalette() =
        listOf(
            FlagPaletteEntry(slot = "cabal-flag-01", label = "Urgent", color = "red"),
            FlagPaletteEntry(slot = "cabal-flag-02", label = "Waiting", color = "blue"),
        )

    /**
     * A palette as a build from before the Enabled switch was removed
     * stored it: `enabled` on every entry, and the first flag switched off.
     */
    private val olderBuildWire =
        """[{"slot":"cabal-flag-01","label":"Urgent","color":"red","enabled":false},""" +
            """{"slot":"\\Flagged","label":"Flagged","color":"yellow","enabled":false},""" +
            """{"slot":"cabal-flag-02","label":"Waiting","color":"blue","enabled":true}]"""

    @Test
    fun `encode decode round-trip`() {
        assertEquals(samplePalette(), FlagPalette.decode(FlagPalette.encode(samplePalette())))
    }

    @Test
    fun `an entry rides the wire as slot label and color`() {
        // `enabled` is deprecated on the server and stops being accepted in
        // 2.0, so this build must never write it.
        assertEquals(
            """[{"slot":"cabal-flag-01","label":"A","color":"red"}]""",
            FlagPalette.encode(listOf(FlagPaletteEntry("cabal-flag-01", "A", "red"))),
        )
        assertFalse("enabled" in FlagPalette.encode(listOf(system()) + samplePalette()))
    }

    @Test
    fun `an unknown color is carried rather than coerced`() {
        // A newer server's vocabulary round-trips back out unchanged.
        val decoded = FlagPalette.decode("""[{"slot":"cabal-flag-03","label":"New","color":"chartreuse"}]""")!!
        assertEquals("chartreuse", decoded.single().color)
        assertTrue("chartreuse" in FlagPalette.encode(decoded))
    }

    @Test
    fun `an older build's enabled is read past and not written back`() {
        // The palette decodes whole, whatever `enabled` says...
        val decoded = FlagPalette.decode(olderBuildWire)!!
        assertEquals(
            listOf(samplePalette()[0], system(), samplePalette()[1]),
            decoded,
        )
        // ...a flag stored as switched off is a flag like any other, here
        // the default one because it is first...
        assertEquals("cabal-flag-01", FlagPalette.defaultEntry(decoded).slot)
        // ...and the next push from this build drops the key.
        val applied =
            PreferencesWire.applyRemote(AppPreferences(), Preferences(app = mapOf("flag_palette" to olderBuildWire)))
        val pushed = PreferencesWire.toUpdate(applied).app!!["flag_palette"]!!
        assertFalse("enabled" in pushed, pushed)
        assertEquals(decoded, FlagPalette.decode(pushed))
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
        assertEquals(20, full.size)
        assertNull(FlagPalette.firstFreeSlot(full))
    }

    @Test
    fun `first free slot ignores the system entry`() {
        // The system flag's entry takes no keyword slot: it neither uses
        // one up nor is ever handed out as free.
        val system = system(label = "Urgent", color = "red")
        assertEquals("cabal-flag-01", FlagPalette.firstFreeSlot(listOf(system)))
        assertEquals("cabal-flag-03", FlagPalette.firstFreeSlot(listOf(system) + samplePalette()))
        val full = listOf(system) + FlagPalette.SLOTS.map { FlagPaletteEntry(it, "x", "red") }
        assertEquals(FlagPalette.MAX_ENTRIES, full.size)
        assertNull(FlagPalette.firstFreeSlot(full))
        assertFalse(FlagPalette.SYSTEM_SLOT in FlagPalette.SLOTS)
    }

    @Test
    fun `slotsIn filters and orders by fixed slot order`() {
        val flags = listOf("\\Seen", "cabal-flag-07", "\\Flagged", "cabal-flag-02", "\$Forwarded")
        assertEquals(listOf("cabal-flag-02", "cabal-flag-07"), FlagPalette.slotsIn(flags))
        assertEquals(emptyList<String>(), FlagPalette.slotsIn(listOf("\\Seen")))
    }

    // ------------------------------------------------ the system flag's entry

    private fun system(
        label: String = "Flagged",
        color: String = "yellow",
    ) = FlagPaletteEntry(slot = FlagPalette.SYSTEM_SLOT, label = label, color = color)

    @Test
    fun `the system slot is the Flagged atom`() {
        // The server accepts exactly this spelling as a palette slot
        // (set_preferences, FLAG_PALETTE_SYSTEM_SLOT), and `set_flag`
        // takes it as the system flag.
        assertEquals("\\Flagged", FlagPalette.SYSTEM_SLOT)
        assertEquals(21, FlagPalette.MAX_ENTRIES)
        assertEquals(system(), FlagPalette.DEFAULT_SYSTEM_ENTRY)
        assertTrue(FlagPalette.DEFAULT_SYSTEM_ENTRY.color in FlagPalette.COLORS)
    }

    @Test
    fun `the effective palette supplies the system entry first`() {
        assertEquals(listOf(system()), FlagPalette.effective(emptyList()))
        assertEquals(listOf(system()) + samplePalette(), FlagPalette.effective(samplePalette()))
    }

    @Test
    fun `the effective palette leaves a stored system entry where it is`() {
        val stored = listOf(samplePalette()[0], system(label = "Urgent", color = "red"), samplePalette()[1])
        assertEquals(stored, FlagPalette.effective(stored))
        // Idempotent: the effective palette is its own effective palette.
        assertEquals(
            FlagPalette.effective(samplePalette()),
            FlagPalette.effective(FlagPalette.effective(samplePalette())),
        )
    }

    @Test
    fun `keyword entries leave out the system entry`() {
        assertEquals(samplePalette(), FlagPalette.keywordEntries(samplePalette()))
        // Left out wherever it sits; the rest keep the palette's order.
        val stored = listOf(samplePalette()[1], system(label = "Urgent", color = "red"), samplePalette()[0])
        assertEquals(
            listOf("cabal-flag-02", "cabal-flag-01"),
            FlagPalette.keywordEntries(stored).map { it.slot },
        )
    }

    @Test
    fun `the default entry is the first one`() {
        // Untouched palette: the system flag, as before the palette had it.
        assertEquals(system(), FlagPalette.defaultEntry(emptyList()))
        assertEquals(system(), FlagPalette.defaultEntry(samplePalette()))
        // Another flag moved to the top takes over.
        assertEquals("cabal-flag-01", FlagPalette.defaultEntry(listOf(samplePalette()[0], system())).slot)
        assertEquals("cabal-flag-02", FlagPalette.defaultEntry(listOf(samplePalette()[1], system())).slot)
        // Position is the whole rule: a stored system entry in first place
        // is the default whatever follows it.
        assertEquals(
            FlagPalette.SYSTEM_SLOT,
            FlagPalette.defaultEntry(listOf(system(label = "Urgent")) + samplePalette()).slot,
        )
    }

    @Test
    fun `there is a default entry even where an older build switched every flag off`() {
        // Such a palette used to have no default flag, and the swipe, the
        // star and the shortcut went inert on it.
        val allOff =
            FlagPalette.decode(
                """[{"slot":"\\Flagged","label":"Flagged","color":"yellow","enabled":false},""" +
                    """{"slot":"cabal-flag-02","label":"Waiting","color":"blue","enabled":false}]""",
            )!!
        assertEquals(system(), FlagPalette.defaultEntry(allOff))
    }

    @Test
    fun `editing another flag does not store the system entry`() {
        // What the user sees has the system entry; what is stored must not
        // gain it from an edit that never touched it.
        val stored = samplePalette()
        val edited =
            FlagPalette.effective(stored).toMutableList().apply {
                this[1] = this[1].copy(label = "Now")
                add(FlagPaletteEntry(slot = "cabal-flag-03", label = "Later", color = "teal"))
            }
        val result = FlagPalette.storedAfterEditing(edited, previous = stored)
        assertEquals(listOf("cabal-flag-01", "cabal-flag-02", "cabal-flag-03"), result.map { it.slot })
        assertEquals("Now", result[0].label)
    }

    @Test
    fun `a no-op edit leaves the wire string byte-identical`() {
        val wire = FlagPalette.encode(samplePalette())
        val stored = FlagPalette.decode(wire)!!
        val result = FlagPalette.storedAfterEditing(FlagPalette.effective(stored), previous = stored)
        assertEquals(wire, FlagPalette.encode(result))
        assertFalse("Flagged" in FlagPalette.encode(result))
        // The empty palette too.
        assertEquals(
            emptyList<FlagPaletteEntry>(),
            FlagPalette.storedAfterEditing(FlagPalette.effective(emptyList()), previous = emptyList()),
        )
    }

    @Test
    fun `editing the system entry stores it in place`() {
        val stored = samplePalette()
        // Renamed or recolored: stored first, where it sat.
        listOf(system(label = "Urgent"), system(color = "red")).forEach { changed ->
            val edited = FlagPalette.effective(stored).toMutableList().apply { this[0] = changed }
            assertEquals(listOf(changed) + stored, FlagPalette.storedAfterEditing(edited, previous = stored))
        }
        // Moved, otherwise untouched: its place is the edit, so it is
        // stored there rather than re-supplied in first place.
        val moved = listOf(stored[0], system(), stored[1])
        assertEquals(moved, FlagPalette.storedAfterEditing(moved, previous = stored))
    }

    @Test
    fun `a stored system entry stays stored once back at the default`() {
        // Put back by hand to the default, in first place: it stays on the
        // wire, because only Reset removes it.
        val previous = listOf(system(label = "Urgent")) + samplePalette()
        val edited = listOf(system()) + samplePalette()
        assertEquals(edited, FlagPalette.storedAfterEditing(edited, previous = previous))
    }

    @Test
    fun `reset removes the stored system entry`() {
        val stored =
            listOf(
                samplePalette()[0],
                system(label = "Urgent", color = "red"),
                samplePalette()[1],
            )
        val reset = FlagPalette.resettingSystemEntry(stored)
        assertEquals(samplePalette(), reset)
        // ...so the default takes over again, in first place.
        assertEquals(listOf(system()) + samplePalette(), FlagPalette.effective(reset))
        assertEquals(samplePalette(), FlagPalette.resettingSystemEntry(samplePalette()))
    }

    @Test
    fun `a stored system entry round-trips on the wire`() {
        val palette = listOf(system(label = "Urgent", color = "red"), samplePalette()[0])
        val wire = FlagPalette.encode(palette)
        // One backslash in the atom, escaped once by JSON.
        assertTrue(""""slot":"\\Flagged"""" in wire, wire)
        assertEquals(palette, FlagPalette.decode(wire))
        // The server's canonical form (keys sorted), as an older build
        // stored it with `enabled`, decodes the same.
        val canonical =
            """[{"color":"red","enabled":true,"label":"Urgent","slot":"\\Flagged"},""" +
                """{"color":"red","enabled":true,"label":"Urgent","slot":"cabal-flag-01"}]"""
        assertEquals(palette, FlagPalette.decode(canonical))
    }

    @Test
    fun `slots in palette order include the system flag`() {
        val flags = listOf("\\Seen", "\\Flagged", "cabal-flag-02", "cabal-flag-01", "\$Forwarded")
        // Untouched palette: the system flag leads, then palette order.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-01", "cabal-flag-02"),
            FlagPalette.slotsIn(flags, samplePalette()),
        )
        // Palette order, not slot order.
        val reordered = listOf(samplePalette()[1], system(), samplePalette()[0])
        assertEquals(
            listOf("cabal-flag-02", FlagPalette.SYSTEM_SLOT, "cabal-flag-01"),
            FlagPalette.slotsIn(flags, reordered),
        )
        // Not flagged: no system slot.
        assertEquals(listOf("cabal-flag-01"), FlagPalette.slotsIn(listOf("cabal-flag-01"), samplePalette()))
        assertEquals(emptyList<String>(), FlagPalette.slotsIn(listOf("\\Seen"), samplePalette()))
    }

    @Test
    fun `the system flag is matched as the envelope matches it`() {
        // `Envelope.isFlagged` ignores case, so a server that answered
        // `\flagged` still draws the flag, under the palette's slot.
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT),
            FlagPalette.slotsIn(listOf("\\flagged"), emptyList()),
        )
    }

    @Test
    fun `slots the palette no longer lists come last in slot order`() {
        // A tag whose palette entry was deleted is still on the message and
        // still has to be removable.
        val flags = listOf("\\Flagged", "cabal-flag-09", "cabal-flag-02", "cabal-flag-05")
        assertEquals(
            listOf(FlagPalette.SYSTEM_SLOT, "cabal-flag-02", "cabal-flag-05", "cabal-flag-09"),
            FlagPalette.slotsIn(flags, samplePalette()),
        )
    }

    @Test
    fun `payload carries a stored system entry and omits an unstored one`() {
        // The default entry the user sees is never pushed on its own: an
        // untouched palette stays off the payload altogether...
        val untouched =
            AppPreferences(
                flagPalette = FlagPalette.storedAfterEditing(FlagPalette.effective(emptyList()), emptyList()),
            )
        assertFalse("flag_palette" in PreferencesWire.toUpdate(untouched).app!!.keys)
        // ...and a palette of keyword flags rides without it.
        val keywordsOnly =
            AppPreferences(
                flagPalette =
                    FlagPalette.storedAfterEditing(FlagPalette.effective(samplePalette()), samplePalette()),
            )
        assertEquals(
            FlagPalette.encode(samplePalette()),
            PreferencesWire.toUpdate(keywordsOnly).app!!["flag_palette"],
        )

        // An edited one rides and applies like any other entry, even alone.
        val edited = listOf(system(label = "Urgent", color = "red"))
        val wire = PreferencesWire.toUpdate(AppPreferences(flagPalette = edited)).app!!["flag_palette"]
        assertEquals(FlagPalette.encode(edited), wire)

        val applied = PreferencesWire.applyRemote(AppPreferences(), Preferences(app = mapOf("flag_palette" to wire!!)))
        assertEquals(edited, applied.flagPalette)
        assertEquals("Urgent", FlagPalette.defaultEntry(applied.flagPalette).label)
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
