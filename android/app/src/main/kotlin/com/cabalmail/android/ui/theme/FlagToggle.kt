package com.cabalmail.android.ui.theme

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import com.cabalmail.android.R
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry

/**
 * A label that is either a fixed string or built around a name the user
 * chose (a flag's). A value, so the rule that picks it unit-tests without
 * Compose; [text] resolves it where it is drawn.
 */
internal sealed interface UiLabel {
    /** A string resource, as is. */
    data class Fixed(
        @StringRes val res: Int,
    ) : UiLabel

    /** The user's own words, as is: a flag's name is the label for setting it. */
    data class Verbatim(
        val value: String,
    ) : UiLabel

    /** A string resource with the user's words in it ("Remove %1$s"). */
    data class Formatted(
        @StringRes val res: Int,
        val arg: String,
    ) : UiLabel
}

@Composable
@ReadOnlyComposable
internal fun UiLabel.text(): String =
    when (this) {
        is UiLabel.Fixed -> stringResource(res)
        is UiLabel.Verbatim -> value
        is UiLabel.Formatted -> stringResource(res, arg)
    }

/**
 * The flag a one-press control sets and clears, and the words and color it
 * does it in: the swipe, the Ctrl+Shift+L shortcut, the selection bar's
 * items, a search result's long-press and the reader's star button. The
 * Kotlin sibling of the Apple app's `FlagToggle`.
 *
 * Mail's controls act on the palette's default flag, the first entry of
 * Settings > Flags ([defaultFlag]). A feed item has one mark, the server's
 * flag, so the feed's controls act on that flag's entry whatever its
 * position ([systemFlag]). There is always one of each: the list always
 * holds the built-in flag, and a flag cannot be switched off.
 */
internal data class FlagToggle(
    val slot: String,
    val label: String,
    val color: String,
) {
    constructor(entry: FlagPaletteEntry) : this(slot = entry.slot, label = entry.label, color = entry.color)

    /**
     * Whether a message's flag list carries this flag. Matched without
     * regard to case, as the server's own flag atoms are everywhere else
     * in the app (`Envelope.isFlagged`).
     */
    fun isSetIn(flags: List<String>): Boolean = flags.any { it.equals(slot, ignoreCase = true) }

    /**
     * What a press does. The built-in flag under its own name keeps the
     * words it always had, so nothing changes for someone who never opened
     * Settings > Flags; any other flag is named: "Urgent" sets it and
     * "Remove Urgent" clears it.
     */
    fun title(isSet: Boolean): UiLabel =
        when {
            keepsClassicWords -> UiLabel.Fixed(if (isSet) R.string.remove_flag else R.string.add_flag)
            isSet -> UiLabel.Formatted(R.string.remove_named_flag, label)
            else -> UiLabel.Verbatim(label)
        }

    private val keepsClassicWords: Boolean
        get() = slot == FlagPalette.SYSTEM_SLOT && label == FlagPalette.DEFAULT_SYSTEM_ENTRY.label

    companion object {
        /** The flag the mail controls toggle: the first entry of the effective palette. */
        fun defaultFlag(palette: List<FlagPaletteEntry>): FlagToggle = FlagToggle(FlagPalette.defaultEntry(palette))

        /**
         * The built-in flag's entry, for the feed controls. The effective
         * palette always holds it.
         */
        fun systemFlag(palette: List<FlagPaletteEntry>): FlagToggle =
            FlagToggle(FlagPalette.effective(palette).first { it.slot == FlagPalette.SYSTEM_SLOT })

        /**
         * The built-in flag's name as a state rather than an action, for
         * the Flagged filter pills and the search sheet's checkbox, which
         * the server can only run on that flag.
         */
        fun systemFlagName(palette: List<FlagPaletteEntry>): String = systemFlag(palette).label
    }
}

/** The flag's palette color, as the tint of a control that shows the flag is set. */
@Composable
@ReadOnlyComposable
internal fun FlagToggle.tint(): Color = ColorTokens.flag(color)

/**
 * One row of a flag menu (the reader's overflow menu and the row's
 * long-press menu): everything the row draws, plus whether it is checked.
 */
internal data class FlagMenuRow(
    val slot: String,
    val label: String,
    val color: String,
    val isOn: Boolean,
)

/**
 * What a flag menu offers. A pure rule so it unit-tests without Compose; the
 * Kotlin sibling of the Apple app's `FlagMenuPolicy`.
 */
internal object FlagMenu {
    /**
     * Every entry of the effective palette in its order, the built-in
     * flag's included, then any flag the message already carries whose
     * entry was deleted — that one still needs an untag affordance (the
     * palette editor's delete confirmation promises tags stay removable).
     * It is labelled by slot id, having no palette entry to name it, and
     * draws gray.
     */
    fun rows(
        palette: List<FlagPaletteEntry>,
        flags: List<String>,
    ): List<FlagMenuRow> {
        val offered = FlagPalette.effective(palette)
        val tagged = FlagPalette.slotsIn(flags, palette).toSet()
        // The built-in flag is always offered, so only a keyword slot can
        // be carried without an entry.
        val stray = FlagPalette.SLOTS.filter { slot -> slot in tagged && offered.none { it.slot == slot } }
        return offered.map { FlagMenuRow(it.slot, it.label, it.color, it.slot in tagged) } +
            stray.map { slot -> FlagMenuRow(slot, label = slot, color = "", isOn = true) }
    }

    /**
     * Whether the default flag is all [rows] holds. A control that already
     * toggles that flag as its own press then has nothing more to offer in
     * a menu, which keeps a palette nobody has added a flag to looking as
     * it always did.
     */
    fun isOnlyTheDefault(
        rows: List<FlagMenuRow>,
        palette: List<FlagPaletteEntry>,
    ): Boolean = rows.size == 1 && rows.single().slot == FlagPalette.defaultEntry(palette).slot
}
