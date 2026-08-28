package com.cabalmail.kit.settings

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * One entry in the user's custom-flag palette
 * (`docs/1.x/rules-composition-and-custom-flags-plan.md`, Phase 3), the
 * Kotlin sibling of the Apple kit's `FlagPaletteEntry`.
 *
 * [slot] is one of the fixed IMAP keyword atoms `cabal-flag-01` ...
 * `cabal-flag-20` (decision 4): the mailstore only ever sees slot atoms,
 * and everything user-visible — label, color, order, enabled — is palette
 * metadata riding synced preferences. [color] stays a raw string rather
 * than an enum on purpose: the server enforces the fixed color set, and a
 * color this build doesn't know (from a newer client) must round-trip
 * unchanged instead of being coerced and re-pushed.
 */
@Serializable
data class FlagPaletteEntry(
    val slot: String,
    val label: String,
    val color: String,
    val enabled: Boolean = true,
)

/**
 * Wire marshalling and limits for the flag palette. The palette rides the
 * synced-preferences `app` map as a JSON-encoded STRING under the
 * `flag_palette` key — deliberately not a nested object, because every
 * shipped client decodes the app map as string-to-string and a nested
 * value would silently break their whole preferences pull. Limits mirror
 * `lambda/api/set_preferences/function.py`, the sole enforcement point.
 */
object FlagPalette {
    const val MAX_ENTRIES = 20
    const val MAX_LABEL_LENGTH = 32

    /** Every assignable slot atom, in order. */
    val SLOTS: List<String> = (1..MAX_ENTRIES).map { "cabal-flag-%02d".format(it) }

    /** The fixed color vocabulary `set_preferences` accepts, in picker order. */
    val COLORS =
        listOf("red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray")

    private val decoder = Json { ignoreUnknownKeys = true }
    private val encoder = Json { encodeDefaults = true }

    /**
     * Decodes the wire string, or null when it doesn't parse — callers keep
     * their current palette rather than adopting garbage.
     */
    fun decode(wire: String): List<FlagPaletteEntry>? =
        runCatching { decoder.decodeFromString<List<FlagPaletteEntry>>(wire) }.getOrNull()

    /** Encodes for the wire; `enabled` always rides, like the Apple kit. */
    fun encode(entries: List<FlagPaletteEntry>): String = encoder.encodeToString(entries)

    /** The lowest slot atom not yet used, or null at the 20-entry cap. */
    fun firstFreeSlot(entries: List<FlagPaletteEntry>): String? =
        SLOTS.firstOrNull { slot -> entries.none { it.slot == slot } }

    /**
     * The slot atoms present in a message's flag list, in fixed slot order
     * — what chips and pickers render (Phase 4). System flags and foreign
     * keywords never leak through.
     */
    fun slotsIn(flags: List<String>): List<String> = SLOTS.filter { it in flags }
}
