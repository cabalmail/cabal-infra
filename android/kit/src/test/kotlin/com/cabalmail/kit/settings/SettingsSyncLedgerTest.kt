package com.cabalmail.kit.settings

import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * [SettingsSyncLedger]'s bookkeeping and [FlagPalette.merged], on plain
 * values: the Kotlin sibling of the Apple kit's `SettingsSyncLedgerTests`.
 * `PreferencesRepositorySyncTest` holds the same rules through the
 * repository.
 */
class SettingsSyncLedgerTest {
    private fun flag(
        number: Int,
        label: String,
        color: String = "blue",
    ) = FlagPaletteEntry(slot = "cabal-flag-%02d".format(number), label = label, color = color)

    private fun holding(
        row: Map<String, String>,
        version: Int?,
    ) = SettingsSyncLedger().rebase(row, version, row).ledger

    // ------------------------------------------------------ the flag list

    @Test
    fun `each side's own change survives`() {
        val base = listOf(flag(1, "Later"), flag(2, "Work"))
        val mine = listOf(flag(1, "Soon"), flag(2, "Work"))
        val theirs = listOf(flag(1, "Later"), flag(2, "Work", "red"), flag(3, "New"))
        assertEquals(
            listOf(flag(1, "Soon"), flag(2, "Work", "red"), flag(3, "New")),
            FlagPalette.merged(base, mine, theirs),
        )
    }

    @Test
    fun `a delete on either side is a delete`() {
        val base = listOf(flag(1, "Later"), flag(2, "Work"), flag(3, "Home"))
        val mine = listOf(flag(1, "Later"), flag(3, "Home"))
        val theirs = listOf(flag(1, "Later"), flag(2, "Work"))
        assertEquals(listOf(flag(1, "Later")), FlagPalette.merged(base, mine, theirs))
    }

    @Test
    fun `a flag added on each side is kept on both`() {
        val base = listOf(flag(1, "Later"))
        assertEquals(
            listOf(flag(1, "Later"), flag(3, "Theirs"), flag(2, "Mine")),
            FlagPalette.merged(base, base + flag(2, "Mine"), base + flag(3, "Theirs")),
        )
    }

    @Test
    fun `the same flag changed on both sides is this device's`() {
        val base = listOf(flag(1, "Later"))
        assertEquals(
            listOf(flag(1, "Mine")),
            FlagPalette.merged(base, listOf(flag(1, "Mine")), listOf(flag(1, "Theirs"))),
        )
        assertEquals(
            listOf(flag(1, "Later"), flag(2, "Mine")),
            FlagPalette.merged(base, base + flag(2, "Mine"), base + flag(2, "Theirs")),
        )
        // Deleted here, renamed there: the delete is this device's change.
        assertEquals(emptyList<FlagPaletteEntry>(), FlagPalette.merged(base, emptyList(), listOf(flag(1, "Theirs"))))
    }

    @Test
    fun `the order is this device's only when it reordered`() {
        // The first flag in the list is the default flag, so the order is
        // a setting too.
        val base = listOf(flag(1, "A"), flag(2, "B"), flag(3, "C"))
        val theirs = listOf(flag(3, "C"), flag(1, "A"), flag(2, "B"), flag(4, "D"))
        val renamed = listOf(flag(1, "A2"), flag(2, "B"), flag(3, "C"))
        assertEquals(
            listOf("cabal-flag-03", "cabal-flag-01", "cabal-flag-02", "cabal-flag-04"),
            FlagPalette.merged(base, renamed, theirs).map { it.slot },
        )
        val moved = listOf(flag(2, "B"), flag(1, "A"), flag(3, "C"))
        assertEquals(
            listOf("cabal-flag-02", "cabal-flag-01", "cabal-flag-03", "cabal-flag-04"),
            FlagPalette.merged(base, moved, theirs).map { it.slot },
        )
    }

    // ---------------------------------------------------------- the ledger

    @Test
    fun `an edit owes its keys, and nothing once they are back at the server's values`() {
        val ledger = holding(mapOf("theme" to "dark", "signature" to "S"), 1)
        val edited = ledger.edited(setOf("theme"), mapOf("theme" to "light", "signature" to "S"))
        assertEquals(mapOf("theme" to "light"), edited.changes(mapOf("theme" to "light", "signature" to "S")))
        val back = edited.edited(setOf("theme"), mapOf("theme" to "dark", "signature" to "S"))
        assertFalse(back.hasUnsent)
        // Before the row is read there is nothing to compare with.
        assertTrue(SettingsSyncLedger().edited(setOf("theme"), mapOf("theme" to "system")).hasUnsent)
    }

    @Test
    fun `what the server took is settled unless it changed since`() {
        val ledger =
            holding(mapOf("theme" to "dark"), 1).edited(
                setOf("theme", "signature"),
                mapOf(
                    "theme" to "light",
                    "signature" to "One",
                ),
            )
        val took =
            ledger.took(
                mapOf("theme" to "light", "signature" to "One"),
                version = 2,
                values = mapOf("theme" to "light", "signature" to "Two"),
            )
        assertEquals(setOf("signature"), took.unsent)
        assertEquals(2, took.version)
        assertEquals("One", took.base["signature"])
    }

    @Test
    fun `a newer row is applied to every key that is not owed`() {
        val ledger =
            holding(mapOf("theme" to "dark", "signature" to "S"), 1).edited(
                setOf("theme"),
                mapOf(
                    "theme" to "light",
                    "signature" to "S",
                ),
            )
        val rebased =
            ledger.rebase(
                mapOf("theme" to "dark", "signature" to "Theirs", "mark_as_read" to "on_open"),
                2,
                mapOf(
                    "theme" to "light",
                    "signature" to "S",
                ),
            )
        assertEquals(mapOf("signature" to "Theirs", "mark_as_read" to "on_open"), rebased.apply)
        assertEquals(setOf("theme"), rebased.ledger.unsent)
        assertEquals(2, rebased.ledger.version)
        assertTrue(rebased.ledger.hasRow)
    }

    @Test
    fun `an owed key the row already holds at this device's value is settled`() {
        // A push whose first copy landed and whose second was refused: the
        // row the refusal answers already holds what this device sent.
        val ledger = holding(mapOf("theme" to "dark"), 1).edited(setOf("theme"), mapOf("theme" to "light"))
        val rebased = ledger.rebase(mapOf("theme" to "light"), 2, mapOf("theme" to "light"))
        assertFalse(rebased.ledger.hasUnsent)
        assertEquals(emptyMap<String, String>(), rebased.apply)
    }

    @Test
    fun `the flag list is compared as a list, not as text`() {
        // The server stores the list in its own spelling.
        val mine = """[{"slot":"cabal-flag-01","label":"Later","color":"blue"}]"""
        val theirs = """[{"color":"blue","label":"Later","slot":"cabal-flag-01"}]"""
        val ledger = holding(mapOf("flag_palette" to theirs), 2)
        assertFalse(ledger.edited(setOf("flag_palette"), mapOf("flag_palette" to mine)).hasUnsent)
    }

    @Test
    fun `it survives the store`() {
        val ledger =
            holding(mapOf("theme" to "dark"), 3).edited(
                setOf("signature"),
                mapOf(
                    "theme" to "dark",
                    "signature" to "x",
                ),
            )
        assertEquals(ledger, Json.decodeFromString<SettingsSyncLedger>(Json.encodeToString(ledger)))
    }
}
