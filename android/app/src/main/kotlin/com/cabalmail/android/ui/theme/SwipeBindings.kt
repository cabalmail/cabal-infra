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
 * current state), its glyph, and its wash. Pure, so it unit-tests without
 * Compose; the composable mapping lives in [painter] / [color].
 */
internal data class SwipeReveal(
    @StringRes val label: Int,
    val glyph: SwipeGlyph,
    val tone: SwipeTone,
)

/** The reveal for a mail row's edge, or null for [MailSwipeAction.NONE] (the edge does not drag). */
internal fun mailSwipeReveal(
    action: MailSwipeAction,
    isSeen: Boolean,
    isFlagged: Boolean,
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
        MailSwipeAction.TOGGLE_FLAG ->
            SwipeReveal(
                label = if (isFlagged) R.string.remove_flag else R.string.add_flag,
                glyph = if (isFlagged) SwipeGlyph.STAR_FILLED else SwipeGlyph.STAR_HOLLOW,
                tone = SwipeTone.FLAG,
            )
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

/** The reveal for a feed item row's edge, or null for [FeedSwipeAction.NONE]. */
internal fun feedSwipeReveal(
    action: FeedSwipeAction,
    isRead: Boolean,
    isFavorite: Boolean,
): SwipeReveal? =
    when (action) {
        FeedSwipeAction.TOGGLE_READ ->
            SwipeReveal(
                label = if (isRead) R.string.mark_unread else R.string.mark_read,
                glyph = SwipeGlyph.EMAIL,
                tone = SwipeTone.READ,
            )
        FeedSwipeAction.TOGGLE_FAVORITE ->
            SwipeReveal(
                label = if (isFavorite) R.string.feed_unfavorite else R.string.feed_favorite,
                glyph = if (isFavorite) SwipeGlyph.STAR_FILLED else SwipeGlyph.STAR_HOLLOW,
                tone = SwipeTone.FLAG,
            )
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
        SwipeTone.FLAG -> ColorTokens.flaggedWash()
        SwipeTone.DISPOSE -> MaterialTheme.colorScheme.errorContainer
        SwipeTone.RESTORE -> MaterialTheme.colorScheme.tertiaryContainer
    }
