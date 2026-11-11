package com.cabalmail.android.ui.theme

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.DisposeIntent
import com.cabalmail.android.ui.mail.disposeVerbRes
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.FeedSwipeAction
import com.cabalmail.kit.settings.MailSwipeAction

/**
 * The list rows' swipe bindings, resolved from the synced preference
 * (`swipe_leading` / `swipe_trailing` for mail, `rss_swipe_leading` /
 * `rss_swipe_trailing` for feeds). Leading is the start edge — a
 * start-to-end drag — so the binding means the same gesture under RTL.
 * Provided app-wide by [CabalmailTheme], like [LocalDisposeToTrash].
 */
data class SwipeBindings(
    val mailLeading: MailSwipeAction,
    val mailTrailing: MailSwipeAction,
    val feedLeading: FeedSwipeAction,
    val feedTrailing: FeedSwipeAction,
) {
    companion object {
        fun of(preferences: AppPreferences): SwipeBindings =
            SwipeBindings(
                mailLeading = preferences.effectiveSwipeLeading,
                mailTrailing = preferences.effectiveSwipeTrailing,
                feedLeading = preferences.effectiveRssSwipeLeading,
                feedTrailing = preferences.effectiveRssSwipeTrailing,
            )
    }
}

val LocalSwipeBindings = staticCompositionLocalOf { SwipeBindings.of(AppPreferences()) }

/** The glyph a revealed swipe edge draws. */
internal enum class SwipeGlyph { EMAIL, STAR_FILLED, STAR_HOLLOW, ARCHIVE, UNARCHIVE, TRASH }

/** The wash behind a revealed swipe edge, by what the action does. */
internal enum class SwipeTone { READ, FLAG, DISPOSE, RESTORE }

/**
 * What a swipe edge shows once revealed: the label (also the icon's
 * content description, naming what the gesture will do — never the
 * current state), its glyph, and its wash. A flag swipe also carries the
 * palette color of the flag it sets, which its wash is drawn in. Pure, so
 * it unit-tests without Compose; the composable mapping lives in [painter]
 * / [color].
 */
internal data class SwipeReveal(
    val label: UiLabel,
    val glyph: SwipeGlyph,
    val tone: SwipeTone,
    /** The palette color name of the flag a [SwipeTone.FLAG] reveal sets; unused by the other tones. */
    val flagColor: String = "",
) {
    constructor(
        @StringRes label: Int,
        glyph: SwipeGlyph,
        tone: SwipeTone,
    ) : this(UiLabel.Fixed(label), glyph, tone)
}

/** The reveal for one flag's toggle: named and colored for [flag], its star filled once the flag is set. */
private fun flagSwipeReveal(
    flag: FlagToggle,
    isSet: Boolean,
): SwipeReveal =
    SwipeReveal(
        label = flag.title(isSet),
        glyph = if (isSet) SwipeGlyph.STAR_FILLED else SwipeGlyph.STAR_HOLLOW,
        tone = SwipeTone.FLAG,
        flagColor = flag.color,
    )

/**
 * The reveal for a mail row's edge, or null when the edge does not drag:
 * for [MailSwipeAction.NONE], and for [MailSwipeAction.TOGGLE_FLAG] while
 * the palette has no default flag to toggle.
 */
internal fun mailSwipeReveal(
    action: MailSwipeAction,
    isSeen: Boolean,
    /** The default flag ([FlagToggle.defaultFlag]), or null when every flag is disabled. */
    flag: FlagToggle?,
    /** Whether the row's message carries [flag]. */
    isFlagSet: Boolean,
    /** What the dispose does in this row's folder: move, restore, or purge. */
    dispose: DisposeIntent,
): SwipeReveal? =
    when (action) {
        MailSwipeAction.TOGGLE_READ ->
            SwipeReveal(
                label = if (isSeen) R.string.mark_unread else R.string.mark_read,
                glyph = SwipeGlyph.EMAIL,
                tone = SwipeTone.READ,
            )
        MailSwipeAction.TOGGLE_FLAG -> flag?.let { flagSwipeReveal(it, isFlagSet) }
        MailSwipeAction.DISPOSE ->
            SwipeReveal(
                label = disposeVerbRes(dispose),
                glyph =
                    when {
                        dispose == DisposeIntent.Restore -> SwipeGlyph.UNARCHIVE
                        dispose == DisposeIntent.Move(DisposeAction.ARCHIVE) -> SwipeGlyph.ARCHIVE
                        else -> SwipeGlyph.TRASH
                    },
                // A restore puts the message back in the inbox rather than
                // removing it, so it drops the dispose wash (as on Apple).
                tone = if (dispose == DisposeIntent.Restore) SwipeTone.RESTORE else SwipeTone.DISPOSE,
            )
        MailSwipeAction.NONE -> null
    }

/**
 * The reveal for a feed item row's edge, or null when the edge does not
 * drag: for [FeedSwipeAction.NONE], and for
 * [FeedSwipeAction.TOGGLE_FAVORITE] while the built-in flag's entry is
 * disabled.
 */
internal fun feedSwipeReveal(
    action: FeedSwipeAction,
    isRead: Boolean,
    /** The built-in flag's entry ([FlagToggle.systemFlag]), the one flag a feed item has. */
    flag: FlagToggle?,
    isFavorite: Boolean,
): SwipeReveal? =
    when (action) {
        FeedSwipeAction.TOGGLE_READ ->
            SwipeReveal(
                label = if (isRead) R.string.mark_unread else R.string.mark_read,
                glyph = SwipeGlyph.EMAIL,
                tone = SwipeTone.READ,
            )
        FeedSwipeAction.TOGGLE_FAVORITE -> flag?.let { flagSwipeReveal(it, isFavorite) }
        FeedSwipeAction.NONE -> null
    }

@Composable
internal fun SwipeReveal.painter(): Painter =
    when (glyph) {
        SwipeGlyph.EMAIL -> rememberVectorPainter(Icons.Default.Email)
        SwipeGlyph.STAR_FILLED -> rememberVectorPainter(Icons.Default.Star)
        SwipeGlyph.STAR_HOLLOW -> painterResource(R.drawable.ic_star_border)
        SwipeGlyph.ARCHIVE -> painterResource(R.drawable.ic_archive)
        SwipeGlyph.UNARCHIVE -> painterResource(R.drawable.ic_unarchive)
        SwipeGlyph.TRASH -> rememberVectorPainter(Icons.Default.Delete)
    }

@Composable
internal fun SwipeReveal.color(): Color =
    when (tone) {
        SwipeTone.READ -> MaterialTheme.colorScheme.secondaryContainer
        // The flag's own palette color, at the opacity the wash token sets.
        SwipeTone.FLAG -> ColorTokens.flag(flagColor).copy(alpha = ColorTokens.flaggedWash().alpha)
        SwipeTone.DISPOSE -> MaterialTheme.colorScheme.errorContainer
        SwipeTone.RESTORE -> MaterialTheme.colorScheme.tertiaryContainer
    }
