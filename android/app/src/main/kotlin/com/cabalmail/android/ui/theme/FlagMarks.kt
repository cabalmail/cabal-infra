package com.cabalmail.android.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The stored flag palette (`AppPreferences.flagPalette`), provided app-wide
 * by [CabalmailTheme] like [LocalSwipeBindings], so every row that draws a
 * flag reads the same list without each screen threading it down. It is the
 * *stored* palette: readers resolve it through [FlagPalette.effective] (as
 * [FlagDotMark.marks] does) to get the system flag's entry.
 */
val LocalFlagPalette = staticCompositionLocalOf<List<FlagPaletteEntry>> { emptyList() }

/**
 * One flag mark on a list row or in the reader's header: the palette entry
 * a flag on the item resolves to, as it is drawn.
 *
 * A value rather than a slot id so that what a row shows can be worked out
 * and tested away from Compose: which flags, in which order, under which
 * names and colors. The Kotlin sibling of the Apple app's `FlagDotMark`.
 */
internal data class FlagDotMark(
    val slot: String,
    /** The palette entry's label, or the slot id for a tag whose entry was deleted. */
    val label: String,
    /** The palette color name; empty for a deleted entry, which draws gray. */
    val color: String,
) {
    companion object {
        /**
         * The most marks a row draws. Rows have a fixed height, and a
         * message can carry every flag in the palette.
         */
        const val ROW_LIMIT = 4

        /**
         * A message's marks: every palette flag it carries, the system flag
         * included, in palette order ([FlagPalette.slotsIn]) and capped at
         * [limit]. A flag whose entry is disabled is still drawn, like every
         * tag that outlives being offered.
         */
        fun marks(
            flags: List<String>,
            palette: List<FlagPaletteEntry>,
            limit: Int = ROW_LIMIT,
        ): List<FlagDotMark> {
            val entries = FlagPalette.effective(palette)
            return FlagPalette.slotsIn(flags, palette).take(limit).map { slot ->
                val entry = entries.firstOrNull { it.slot == slot }
                FlagDotMark(slot = slot, label = entry?.label ?: slot, color = entry?.color.orEmpty())
            }
        }

        /**
         * A feed item's marks. A feed item has one flag, stored as its
         * favorite bit, and it is the system flag: the mark takes the name
         * and color of the palette's entry for it, as a flagged message's
         * does.
         */
        fun feedMarks(
            isFlagged: Boolean,
            palette: List<FlagPaletteEntry>,
        ): List<FlagDotMark> = marks(if (isFlagged) listOf(FlagPalette.SYSTEM_SLOT) else emptyList(), palette)
    }
}

/**
 * One flag mark as a row draws it: a dot in the flag's palette color, named
 * for a screen reader. This is the only rendering a flag has on a row — the
 * system flag draws the same dot as a custom one, so a row shows one kind
 * of flag rather than a star for one and dots for the rest.
 */
@Composable
internal fun FlagDot(
    mark: FlagDotMark,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier =
            modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(ColorTokens.flag(mark.color))
                .semantics { contentDescription = mark.label },
    )
}
