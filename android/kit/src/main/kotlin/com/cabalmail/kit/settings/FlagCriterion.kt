package com.cabalmail.kit.settings

/**
 * What a list is narrowed to when the user picks from the Flagged pill's
 * menu (`docs/1.x/post-wave-3/flags-and-cross-media.md`, decision 4): one
 * flag, or any flag at all. The Kotlin sibling of the Apple kit's
 * `FlagCriterion`. A pick is for the visit and is never stored; the
 * remembered Flagged filter (`MailFolderFilter.FLAGGED`,
 * `RssItemFilter.FAVORITE`) stays what it was, the built-in flag.
 */
sealed interface FlagCriterion {
    /** One flag, by its palette slot: the built-in flag's, or one of the user's own. */
    data class Slot(
        val slot: String,
    ) : FlagCriterion

    /**
     * The built-in flag or any of the twenty slots, so an item still
     * tagged with a flag that was deleted is found too.
     */
    data object AnyFlag : FlagCriterion

    /**
     * Whether an item carrying [flags] is one the criterion finds. [flags]
     * is a message's flag list or a feed item's
     * (`RssItem.paletteFlags`); the built-in flag's atom is matched
     * without regard to case, as it is everywhere else.
     */
    fun matches(flags: List<String>): Boolean =
        when (this) {
            is Slot -> flags.any { it.equals(slot, ignoreCase = true) }
            AnyFlag -> flags.any { it.equals(FlagPalette.SYSTEM_SLOT, ignoreCase = true) || it in FlagPalette.SLOTS }
        }
}
