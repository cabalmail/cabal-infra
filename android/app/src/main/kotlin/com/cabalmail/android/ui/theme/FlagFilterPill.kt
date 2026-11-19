package com.cabalmail.android.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cabalmail.android.R
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/** One row of the Flagged pill's menu: what choosing it narrows the list to, and how it is drawn. */
internal data class FlagFilterRow(
    val criterion: FlagCriterion,
    val label: UiLabel,
    /** The flag's palette color name; null for Any flag, which draws no dot. */
    val color: String?,
    val isChecked: Boolean,
)

/** What choosing a row of the Flagged pill's menu does to the list. */
internal sealed interface FlagFilterChoice {
    /**
     * The built-in flag's row: the Flagged filter the folder or feed has
     * always had, remembered as a pill is.
     */
    data object BuiltIn : FlagFilterChoice

    /** A flag of the user's own, or Any flag: for the visit, and nothing is stored. */
    data class Pick(
        val criterion: FlagCriterion,
    ) : FlagFilterChoice
}

/**
 * The rules of the Flagged pill once Settings > Flags holds a flag of the
 * user's own (`docs/1.x/post-wave-3/flags-and-cross-media.md`, decision
 * 4): the pill is then a menu and nothing else, with a row for every flag
 * in the list's order, Any flag and Clear filter. With the built-in flag
 * alone it stays the plain toggle it was. Pure, so it unit-tests without
 * Compose; the Kotlin sibling of the Apple app's `FlagFilterMenuPolicy`.
 *
 * Throughout, `builtInLit` is whether the list's remembered filter is the
 * Flagged one, and `pick` the criterion picked for this visit, if any. A
 * pick takes over the list while it is in force, and the remembered
 * filter comes back when it ends.
 */
internal object FlagFilterMenu {
    /** The most characters of a picked flag's name the lit pill draws; the menu has it whole. */
    const val LABEL_LIMIT = 20

    /** Whether the pill opens a menu rather than toggling. */
    fun isMenu(
        palette: List<FlagPaletteEntry>,
        pick: FlagCriterion?,
    ): Boolean = pick != null || FlagPalette.keywordEntries(palette).isNotEmpty()

    /** Whether the pill is lit: by the remembered Flagged filter, or by a pick. */
    fun isLit(
        builtInLit: Boolean,
        pick: FlagCriterion?,
    ): Boolean = builtInLit || pick != null

    /**
     * Every flag in Settings > Flags, in its order, then Any flag. A slot
     * whose flag was deleted has no row: Any flag is how to find what
     * still carries it.
     */
    fun rows(
        palette: List<FlagPaletteEntry>,
        builtInLit: Boolean,
        pick: FlagCriterion?,
    ): List<FlagFilterRow> =
        FlagPalette.effective(palette).map { entry ->
            val criterion = FlagCriterion.Slot(entry.slot)
            val isBuiltIn = entry.slot == FlagPalette.SYSTEM_SLOT
            FlagFilterRow(
                criterion = criterion,
                label = UiLabel.Verbatim(entry.label),
                color = entry.color,
                isChecked = if (isBuiltIn) builtInLit && pick == null else pick == criterion,
            )
        } +
            FlagFilterRow(
                criterion = FlagCriterion.AnyFlag,
                label = UiLabel.Fixed(R.string.flag_filter_any),
                color = null,
                isChecked = pick == FlagCriterion.AnyFlag,
            )

    /** What choosing [row] does: the built-in flag's row is the remembered filter, every other a pick. */
    fun choice(row: FlagFilterRow): FlagFilterChoice =
        if (row.criterion == FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)) {
            FlagFilterChoice.BuiltIn
        } else {
            FlagFilterChoice.Pick(row.criterion)
        }

    /**
     * The pill's words: the picked flag's name, cut to [LABEL_LIMIT], or
     * "Any flag"; with no pick, the built-in flag's name, as the plain
     * pill has it. A picked slot whose flag has since been deleted is
     * named by its slot id.
     */
    fun pillLabel(
        palette: List<FlagPaletteEntry>,
        pick: FlagCriterion?,
    ): UiLabel =
        when (pick) {
            null -> UiLabel.Verbatim(FlagToggle.systemFlagName(palette))
            FlagCriterion.AnyFlag -> UiLabel.Fixed(R.string.flag_filter_any)
            is FlagCriterion.Slot -> UiLabel.Verbatim(cut(name(palette, pick)))
        }

    /** The picked flag's name whole, for words that have room for it. */
    fun name(
        palette: List<FlagPaletteEntry>,
        pick: FlagCriterion.Slot,
    ): String =
        FlagPalette
            .effective(palette)
            .firstOrNull { it.slot == pick.slot }
            ?.label ?: pick.slot

    private fun cut(name: String): String = if (name.length <= LABEL_LIMIT) name else name.take(LABEL_LIMIT - 1) + "…"
}

/**
 * The Flagged pill of a folder's list and of a feed list. A plain toggle
 * while the built-in flag is the only one; otherwise a tap opens the menu
 * of [FlagFilterMenu]. [count], when there is one, is the built-in flag's
 * and is drawn only while no pick is in force.
 */
@Composable
internal fun FlagFilterPill(
    palette: List<FlagPaletteEntry>,
    builtInLit: Boolean,
    pick: FlagCriterion?,
    count: Int?,
    onToggleBuiltIn: () -> Unit,
    onChoose: (FlagFilterChoice) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val name = FlagFilterMenu.pillLabel(palette, pick).text()
    val label = if (count != null && pick == null) "$name $count" else name
    if (!FlagFilterMenu.isMenu(palette, pick)) {
        FilterChip(selected = builtInLit, onClick = onToggleBuiltIn, label = { Text(label) }, modifier = modifier)
        return
    }
    var open by remember { mutableStateOf(false) }
    val lit = FlagFilterMenu.isLit(builtInLit, pick)
    Box(modifier = modifier) {
        FilterChip(selected = lit, onClick = { open = true }, label = { Text(label) })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            FlagFilterMenu.rows(palette, builtInLit, pick).forEach { row ->
                DropdownMenuItem(
                    text = { Text(row.label.text()) },
                    leadingIcon = {
                        when {
                            row.isChecked ->
                                Icon(Icons.Default.Check, contentDescription = stringResource(R.string.active_option))
                            row.color != null ->
                                Box(Modifier.size(10.dp).clip(CircleShape).background(ColorTokens.flag(row.color)))
                            else -> Box(Modifier.size(10.dp))
                        }
                    },
                    onClick = {
                        open = false
                        onChoose(FlagFilterMenu.choice(row))
                    },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.flag_filter_clear)) },
                // Live only while the pill is lit: there is nothing to clear otherwise.
                enabled = lit,
                onClick = {
                    open = false
                    onClear()
                },
            )
        }
    }
}
