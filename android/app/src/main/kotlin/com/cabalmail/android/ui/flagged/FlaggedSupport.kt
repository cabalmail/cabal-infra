package com.cabalmail.android.ui.flagged

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.FlagFilterMenu
import com.cabalmail.android.ui.theme.FlagFilterRow
import com.cabalmail.android.ui.theme.UiLabel
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * The Flagged view's two doors. It belongs to neither medium, so it is
 * reached from both: a row above the folders in Mail and a row above All
 * Feeds in Feeds (`docs/1.x/cross-media-ux-plan.md`, "Open decisions",
 * answered 2026-11-22). Each door is a route of its own so that Back
 * returns to the list it was opened from, and the bar or rail keeps that
 * medium lit.
 */
object FlaggedRoutes {
    /** From Mail's folder list. */
    const val FROM_MAIL = "flagged"

    /** From the feed tree. */
    const val FROM_FEEDS = "feeds/flagged"
}

/**
 * The rules of the view's flag pill. The view opens on any flag, which is
 * what "Flagged" promises once there are several; the pill narrows it to
 * one for the visit. With the built-in flag alone there is nothing to
 * narrow to, and no pill. Pure, so it unit-tests without Compose.
 */
internal object FlaggedPicker {
    private val builtIn = FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)

    /**
     * Whether the pill is drawn: the list holds a flag of the user's own,
     * or a pick is in force and needs a way back.
     */
    fun isShown(
        palette: List<FlagPaletteEntry>,
        criterion: FlagCriterion,
    ): Boolean = criterion != FlagCriterion.AnyFlag || FlagPalette.keywordEntries(palette).isNotEmpty()

    /** Whether the view is narrowed to one flag. */
    fun isNarrowed(criterion: FlagCriterion): Boolean = criterion != FlagCriterion.AnyFlag

    /** Every flag in Settings > Flags, in its order, then Any flag: the lists' menu, with the pick checked. */
    fun rows(
        palette: List<FlagPaletteEntry>,
        criterion: FlagCriterion,
    ): List<FlagFilterRow> =
        FlagFilterMenu.rows(
            palette = palette,
            builtInLit = criterion == builtIn,
            pick = criterion.takeUnless { it == builtIn },
        )

    /** The pill's words: the picked flag's name, or "Any flag". */
    fun label(
        palette: List<FlagPaletteEntry>,
        criterion: FlagCriterion,
    ): UiLabel = FlagFilterMenu.pillLabel(palette, criterion)

    /** What the empty list says: nothing flagged at all, or nothing under the picked flag's name. */
    fun emptyTitle(
        palette: List<FlagPaletteEntry>,
        criterion: FlagCriterion,
    ): UiLabel =
        when (criterion) {
            FlagCriterion.AnyFlag -> UiLabel.Fixed(R.string.flagged_empty_any)
            is FlagCriterion.Slot ->
                UiLabel.Formatted(
                    R.string.flagged_empty_flag,
                    FlagFilterMenu.name(palette, criterion),
                )
        }
}

/**
 * The door itself: one row, drawn the same above the folders and above
 * All Feeds. It carries no count: a count of flagged mail is a search of
 * every folder, which a list that refreshes on a timer should not pay
 * for.
 */
@Composable
internal fun FlaggedEntryRow(
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ListItem(
        headlineContent = { Text(stringResource(R.string.flagged_title)) },
        leadingContent = {
            Icon(
                Icons.Filled.Star,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        },
        modifier = modifier.clickable(role = Role.Button, onClick = onOpen),
    )
}
