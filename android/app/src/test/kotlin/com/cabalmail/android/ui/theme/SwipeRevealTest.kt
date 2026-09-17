package com.cabalmail.android.ui.theme

import com.cabalmail.android.R
import com.cabalmail.android.ui.mail.DisposeIntent
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.DisposeAction
import com.cabalmail.kit.settings.FeedSwipeAction
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
            mailSwipeReveal(MailSwipeAction.TOGGLE_READ, isSeen = false, isFlagged = false, archive),
        )
        assertEquals(
            SwipeReveal(R.string.mark_unread, SwipeGlyph.EMAIL, SwipeTone.READ),
            mailSwipeReveal(MailSwipeAction.TOGGLE_READ, isSeen = true, isFlagged = false, archive),
        )
        assertEquals(
            SwipeReveal(R.string.add_flag, SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, isFlagged = false, archive),
        )
        assertEquals(
            SwipeReveal(R.string.remove_flag, SwipeGlyph.STAR_FILLED, SwipeTone.FLAG),
            mailSwipeReveal(MailSwipeAction.TOGGLE_FLAG, isSeen = true, isFlagged = true, archive),
        )
    }

    @Test
    fun `dispose follows the preference and purges inside Trash`() {
        assertEquals(
            SwipeReveal(R.string.archive, SwipeGlyph.ARCHIVE, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                false,
                DisposeIntent.standard(DisposeAction.ARCHIVE, "INBOX"),
            ),
        )
        assertEquals(
            SwipeReveal(R.string.dispose_to_trash, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(MailSwipeAction.DISPOSE, true, false, DisposeIntent.standard(DisposeAction.TRASH, "INBOX")),
        )
        assertEquals(
            SwipeReveal(R.string.purge, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
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
                false,
                DisposeIntent.standard(DisposeAction.ARCHIVE, "Archive"),
            ),
        )
        assertEquals(
            SwipeReveal(R.string.dispose_to_trash, SwipeGlyph.TRASH, SwipeTone.DISPOSE),
            mailSwipeReveal(
                MailSwipeAction.DISPOSE,
                true,
                false,
                DisposeIntent.standard(DisposeAction.TRASH, "Archive"),
            ),
        )
    }

    @Test
    fun `none reveals nothing on either list`() {
        assertNull(mailSwipeReveal(MailSwipeAction.NONE, false, false, archive))
        assertNull(feedSwipeReveal(FeedSwipeAction.NONE, isRead = false, isFavorite = false))
    }

    @Test
    fun `feed reveals mirror the mail ones with favorite in place of flag`() {
        assertEquals(
            SwipeReveal(R.string.mark_unread, SwipeGlyph.EMAIL, SwipeTone.READ),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_READ, isRead = true, isFavorite = false),
        )
        assertEquals(
            SwipeReveal(R.string.feed_favorite, SwipeGlyph.STAR_HOLLOW, SwipeTone.FLAG),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_FAVORITE, isRead = true, isFavorite = false),
        )
        assertEquals(
            SwipeReveal(R.string.feed_unfavorite, SwipeGlyph.STAR_FILLED, SwipeTone.FLAG),
            feedSwipeReveal(FeedSwipeAction.TOGGLE_FAVORITE, isRead = true, isFavorite = true),
        )
    }
}
