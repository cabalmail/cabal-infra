package com.cabalmail.android.ui.mail

import com.cabalmail.android.R
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Test

/**
 * The reader's read toggle (#2171): its label follows the message's state,
 * as the flag toggle's does (`ReaderFlagToggleTest`). Before, both states
 * read "Toggle read", so TalkBack never named the action.
 */
class ReaderReadToggleTest {
    @Test
    fun `an unread message offers to mark it read`() {
        assertEquals(R.string.mark_read, readerReadToggleLabel(false))
    }

    @Test
    fun `a read message offers to mark it unread`() {
        assertEquals(R.string.mark_unread, readerReadToggleLabel(true))
    }

    @Test
    fun `the two states do not share a label`() {
        assertNotEquals(readerReadToggleLabel(false), readerReadToggleLabel(true))
    }

    /**
     * The mail surface speaks one pair of strings: the list's own row action
     * picks between exactly these two for the same state (MessageListScreen),
     * so the reader agreeing with it is the point of the fix.
     */
    @Test
    fun `the labels are the mail surface's pair, not the feed reader's`() {
        assertNotEquals(R.string.feed_mark_as_read, readerReadToggleLabel(false))
        assertNotEquals(R.string.feed_mark_as_unread, readerReadToggleLabel(true))
    }
}
