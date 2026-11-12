package com.cabalmail.android.ui.theme

import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.DisposeIntent
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.FeedSwipeAction
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.MailSwipeAction
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * The configurable swipe edges: what each binding reveals, and that the
 * untouched preference reproduces the historical arrangement (leading
 * toggles read, trailing disposes / favorites).
 */
class SwipeRevealTest {
    private val archive = DisposeIntent.Move(DisposeAction.ARCHIVE)

    /** The default flag of an untouched palette: the built-in flag under its own name. */
    private val builtIn = FlagToggle.defaultFlag(emptyList())
    private val todo = FlagToggle(slot = "cabal-flag-01", label = "Todo", color = "blue")

    @Test
    fun `an untouched preference keeps the historical arrangement`() {
        val bindings = SwipeBindings.of(AppPreferences())
        assertEquals(MailSwipeAction.TOGGLE_READ, bindings.mailLeading)
        assertEquals(MailSwipeAction.DISPOSE, bindings.mailTrailing)
        assertEquals(FeedSwipeAction.TOGGLE_READ, bindings.feedLeading)
        assertEquals(FeedSwipeAction.TOGGLE_FAVORITE, bindings.feedTrailing)
    }

    @Test
    fun `read and flag reveals name what the gesture will do`() {
        assertEquals(
            SwipeReveal(R.string.mark_read, SwipeGlyph.EMAIL, SwipeTone.READ),
            mailSwipeReveal(MailSwipeAction.TOGGLE_READ, isSeen = false, flag = builtIn, isFlagSet = false, archive),
        )
        assertEquals(
            SwipeReveal(R.string.mark_unread, SwipeGlyph.EMAIL, SwipeTone.READ),
            mailSwipeReveal(MailSwipeAction.TOGGLE_READ, isSeen = true, flag = builtIn, isFlagSet = false, archive),
        )
        // An untouched palette keeps the words the flag swipe always had,
        // washed in the built-in flag's color.
        assertEquals(
            SwipeReveal(UiLabel.Fixed(R.string.add_flag), SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG, flagColor = "yellow"),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, flag = builtIn, isFlagSet = false, archive),
        )
        assertEquals(
            SwipeReveal(
                UiLabel.Fixed(R.string.remove_flag),
                SwipeGlyph.STAR_FILLED,
                SwipeTone.FLAG,
                flagColor = "yellow",
            ),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, flag = builtIn, isFlagSet = true, archive),
        )
    }

    @Test
    fun `the flag swipe takes the default flag's name and color`() {
        assertEquals(
            SwipeReveal(UiLabel.Verbatim("Todo"), SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG, flagColor = "blue"),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, flag = todo, isFlagSet = false, archive),
        )
        assertEquals(
            SwipeReveal(
                UiLabel.Formatted(R.string.remove_named_flag, "Todo"),
                SwipeGlyph.STAR_FILLED,
                SwipeTone.FLAG,
                flagColor = "blue",
            ),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, flag = todo, isFlagSet = true, archive),
        )
    }

    @Test
    fun `the flag edge drags on a palette whose flags an older build switched off`() {
        // Such a palette used to have no flag to toggle, and the edge bound
        // to the flag did not drag in mail or in a feed.
        val allOff =
            FlagPalette.decode(
                """[{"slot":"\\Flagged","label":"Urgent","color":"red","enabled":false},""" +
                    """{"slot":"cabal-flag-01","label":"Todo","color":"blue","enabled":false}]""",
            )!!
        assertEquals(
            SwipeReveal(UiLabel.Verbatim("Urgent"), SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG, flagColor = "red"),
            mailSwipeReveal(
                MailSwipeAction.TOGGLE_FLAG,
                isSeen = true,
                flag = FlagToggle.defaultFlag(allOff),
                isFlagSet = false,
                archive,
            ),
        )
        assertEquals(
            SwipeReveal(UiLabel.Verbatim("Urgent"), SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG, flagColor = "red"),
            feedSwipeReveal(
                FeedSwipeAction.TOGGLE_FAVORITE,
                isRead = true,
                flag = FlagToggle.systemFlag(allOff),
                isFavorite = false,
            ),
        )
    }

    @Test
    fun `dispose follows the preference and purges inside Trash`() {
        assertEquals(
            SwipeReveal(R.string.archive, SwipeGlyph.ARCHIVE, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                builtIn,
                false,
                DisposeIntent.standard(DisposeAction.ARCHIVE, "INBOX"),
            ),
        )
        assertEquals(
            SwipeReveal(R.string.dispose_to_trash, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                builtIn,
                false,
                DisposeIntent.standard(DisposeAction.TRASH, "INBOX"),
            ),
        )
        assertEquals(
            SwipeReveal(R.string.purge, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                builtIn,
                false,
                DisposeIntent.standard(DisposeAction.ARCHIVE, "Trash"),
            ),
        )
    }

    @Test
    fun `dispose inside Archive says restore, as the reader's button does`() {
        // #1619: the row said Archive (and moved the message onto its own
        // folder) while the reader's button on the same message said Restore.
        assertEquals(
            SwipeReveal(R.string.restore, SwipeGlyph.UNARCHIVE, SwipeTone.RESTORE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                builtIn,
                false,
                DisposeIntent.standard(DisposeAction.ARCHIVE, "Archive"),
            ),
        )
        assertEquals(
            SwipeReveal(R.string.dispose_to_trash, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                builtIn,
                false,
                DisposeIntent.standard(DisposeAction.TRASH, "Archive"),
            ),
        )
    }

    @Test
    fun `none reveals nothing on either list`() {
        assertNull(mailSwipeReveal(MailSwipeAction.NONE, false, builtIn, false, archive))
        assertNull(feedSwipeReveal(FeedSwipeAction.NONE, isRead = false, flag = builtIn, isFavorite = false))
    }

    @Test
    fun `feed reveals mirror the mail ones, on the built-in flag's entry`() {
        assertEquals(
            SwipeReveal(R.string.mark_unread, SwipeGlyph.EMAIL, SwipeTone.READ),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_READ, isRead = true, flag = builtIn, isFavorite = false),
        )
        assertEquals(
            SwipeReveal(UiLabel.Fixed(R.string.add_flag), SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG, flagColor = "yellow"),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_FAVORITE, isRead = true, flag = builtIn, isFavorite = false),
        )
        assertEquals(
            SwipeReveal(
                UiLabel.Fixed(R.string.remove_flag),
                SwipeGlyph.STAR_FILLED,
                SwipeTone.FLAG,
                flagColor = "yellow",
            ),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_FAVORITE, isRead = true, flag = builtIn, isFavorite = true),
        )
        // Renamed and recolored in Settings > Flags: the feed's swipe follows.
        val urgent = FlagToggle(slot = FlagPalette.SYSTEM_SLOT, label = "Urgent", color = "red")
        assertEquals(
            SwipeReveal(
                UiLabel.Formatted(R.string.remove_named_flag, "Urgent"),
                SwipeGlyph.STAR_FILLED,
                SwipeTone.FLAG,
                "red",
            ),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_FAVORITE, isRead = true, flag = urgent, isFavorite = true),
        )
    }
}
