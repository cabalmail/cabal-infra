package com.cabalmail.kit.settings

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * One entry in the user's flag palette
 * (`docs/1.x/rules-composition-and-custom-flags-plan.md`, Phase 3), the
 * Kotlin sibling of the Apple kit's `FlagPaletteEntry`.
 *
 * [slot] is one of the fixed IMAP keyword atoms `cabal-flag-01` ...
 * `cabal-flag-20` (decision 4): the mailstore only ever sees slot atoms,
 * and everything user-visible — label, color, order — is palette
 * metadata riding synced preferences. One entry is not a keyword:
 * [FlagPalette.SYSTEM_SLOT] stands for the system `\Flagged` flag
 * (`docs/1.x/unified-flags-plan.md`), which every mailbox has and no
 * palette edit can remove. [color] stays a raw string rather
 * than an enum on purpose: the server enforces the fixed color set, and a
 * color this build doesn't know (from a newer client) must round-trip
 * unchanged instead of being coerced and re-pushed.
 *
 * An entry has no `enabled`: a flag is in the palette or it is deleted
 * (`docs/1.x/post-wave-3/flags-and-cross-media.md`, decision 10). A
 * palette stored by an older build still carries the key; it is skipped
 * on decode and never written, so the next push from this build drops it.
 */
@Serializable
data class FlagPaletteEntry(
    val slot: String,
    val label: String,
    val color: String,
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
    /** The keyword slots a user can fill. */
    private const val KEYWORD_SLOT_COUNT = 20

    /** The 20 keyword slots plus the system flag's entry. */
    const val MAX_ENTRIES = KEYWORD_SLOT_COUNT + 1
    const val MAX_LABEL_LENGTH = 32

    /**
     * Every assignable keyword slot atom, in order. [SYSTEM_SLOT] is not
     * one of them: it is never handed out and never runs out.
     */
    val SLOTS: List<String> = (1..KEYWORD_SLOT_COUNT).map { "cabal-flag-%02d".format(it) }

    /**
     * The palette slot of the system `\Flagged` flag: the IMAP atom itself
     * rather than a made-up id, so an entry's slot is the flag `set_flag`
     * sets whichever entry it is, and a build that predates the entry sets
     * the system flag when the user picks it
     * (`docs/1.x/unified-flags-plan.md`, decision 1).
     */
    const val SYSTEM_SLOT = "\\Flagged"

    /**
     * The system flag's entry for a palette that stores none (decision 2).
     * Yellow shares its hue with the `flagged.fg` token, so the flag keeps
     * the color it had before it had an entry.
     */
    val DEFAULT_SYSTEM_ENTRY = FlagPaletteEntry(slot = SYSTEM_SLOT, label = "Flagged", color = "yellow")

    /** The fixed color vocabulary `set_preferences` accepts, in picker order. */
    val COLORS =
        listOf("red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray")

    // Unknown keys are skipped, which is what reads an older build's
    // `enabled` (and anything a newer one adds) without failing the palette.
    private val decoder = Json { ignoreUnknownKeys = true }

    /**
     * Decodes the wire string, or null when it doesn't parse — callers keep
     * their current palette rather than adopting garbage.
     */
    fun decode(wire: String): List<FlagPaletteEntry>? =
        runCatching { decoder.decodeFromString<List<FlagPaletteEntry>>(wire) }.getOrNull()

    /** Encodes for the wire: `{slot, label, color}` an entry, in palette order. */
    fun encode(entries: List<FlagPaletteEntry>): String = Json.encodeToString(entries)

    /**
     * What Settings names a new flag before the user names it, and the
     * name a flag of the user's own gets back when it is stored with an
     * empty one. The app shows its localized string for a new flag; this
     * is what a stored value falls back to where no resources are in reach.
     */
    const val NEW_FLAG_LABEL = "New flag"

    /**
     * The name an entry has before the user gives it one: the built-in
     * flag's own for its entry ("Flagged"), [NEW_FLAG_LABEL] for any other.
     */
    fun defaultLabel(slot: String): String = if (slot == SYSTEM_SLOT) DEFAULT_SYSTEM_ENTRY.label else NEW_FLAG_LABEL

    /**
     * [entries] with every name as the server takes it
     * ([ServerTextRules.flagLabel]); a name that comes out empty is the
     * entry's default one ([defaultLabel]). The flag editor writes no such
     * name, so this names an entry that got one another way: builds up to
     * 1.53.0 stored a cleared name as it was typed (#2453).
     */
    fun accepted(entries: List<FlagPaletteEntry>): List<FlagPaletteEntry> =
        entries.map { entry ->
            val label = ServerTextRules.flagLabel(entry.label)
            val named = label.ifEmpty { defaultLabel(entry.slot) }
            if (named == entry.label) entry else entry.copy(label = named)
        }

    /** The lowest keyword slot not yet used, or null once all 20 are. */
    fun firstFreeSlot(entries: List<FlagPaletteEntry>): String? =
        SLOTS.firstOrNull { slot -> entries.none { it.slot == slot } }

    /**
     * The keyword slots present in a message's flag list, in fixed slot
     * order. The system flag is not among them, and foreign keywords never
     * leak through; the two-argument [slotsIn] is the form that includes
     * the system flag and follows the palette's order.
     */
    fun slotsIn(flags: List<String>): List<String> = SLOTS.filter { it in flags }

    // ------------------------------------------------ the system flag's entry
    //
    // Two palettes are in play (`docs/1.x/unified-flags-plan.md`). The
    // *stored* palette is what [AppPreferences.flagPalette] holds and what
    // rides the wire. The *effective* palette is what the user sees: the
    // stored one, with the system flag's entry supplied when the stored one
    // has none. The entry is only stored once the user has changed it, so
    // the palette of a user who never touches it stays as it was on every
    // device and on the server.

    /**
     * The palette as the user sees it: [stored], led by
     * [DEFAULT_SYSTEM_ENTRY] when it has no entry for the system flag.
     */
    fun effective(stored: List<FlagPaletteEntry>): List<FlagPaletteEntry> =
        if (stored.any { it.slot == SYSTEM_SLOT }) stored else listOf(DEFAULT_SYSTEM_ENTRY) + stored

    /**
     * The keyword entries alone, in palette order: what a picker offers
     * beside a control that already toggles the system flag, and the only
     * slots a rule's `flags` list may name.
     */
    fun keywordEntries(stored: List<FlagPaletteEntry>): List<FlagPaletteEntry> =
        stored.filter { it.slot != SYSTEM_SLOT }

    /**
     * The flag the one-gesture toggles act on (the swipe, the shortcut, the
     * reader's button): the first entry of the effective palette. There is
     * always one, since the effective palette always holds the system
     * flag's entry.
     */
    fun defaultEntry(stored: List<FlagPaletteEntry>): FlagPaletteEntry = effective(stored).first()

    /**
     * What to store after the user edits the effective palette.
     *
     * The system entry is left out when it is still exactly what
     * [effective] would supply — the default entry, in first place — and
     * [previous], the stored palette the edit started from, had none. Once
     * stored it stays, even if a later edit puts it back to the default:
     * only [resettingSystemEntry] removes it. So saving an edit to some
     * other flag never adds the entry, and a user who has arranged the
     * palette keeps the arrangement.
     */
    fun storedAfterEditing(
        edited: List<FlagPaletteEntry>,
        previous: List<FlagPaletteEntry>,
    ): List<FlagPaletteEntry> {
        val wasStored = previous.any { it.slot == SYSTEM_SLOT }
        return if (!wasStored && edited.firstOrNull() == DEFAULT_SYSTEM_ENTRY) edited.drop(1) else edited
    }

    /**
     * "Reset to default" for the system entry, which cannot be deleted:
     * drops the stored entry so [effective] supplies the default again, in
     * first place.
     */
    fun resettingSystemEntry(stored: List<FlagPaletteEntry>): List<FlagPaletteEntry> = keywordEntries(stored)

    /**
     * The palette slots a message carries, in the order dots and chips draw
     * them: the effective palette's order, the system flag included. A
     * keyword slot the message carries but the palette no longer lists
     * comes last, in slot order, so its tag can still be shown and
     * removed. The system flag's atom is
     * matched without regard to case, as [com.cabalmail.kit.models.Envelope.isFlagged]
     * matches it, and reported as [SYSTEM_SLOT].
     */
    fun slotsIn(
        flags: List<String>,
        stored: List<FlagPaletteEntry>,
    ): List<String> {
        val listed = effective(stored).map { it.slot }.filter { carries(flags, it) }
        return listed + slotsIn(flags).filter { it !in listed }
    }

    private fun carries(
        flags: List<String>,
        slot: String,
    ): Boolean = if (slot == SYSTEM_SLOT) flags.any { it.equals(SYSTEM_SLOT, ignoreCase = true) } else slot in flags
}
