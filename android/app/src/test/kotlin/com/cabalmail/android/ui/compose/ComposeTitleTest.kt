package com.cabalmail.android.ui.compose

import com.cabalmail.kit.models.ComposeIntent
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * [ComposeTitle] (#1290): a session resumed from the Drafts folder is a
 * draft, whatever compose intent its seed carries.
 */
class ComposeTitleTest {
    @Test
    fun `a fresh compose is a new message`() {
        assertEquals(
            ComposeTitleKind.NEW,
            ComposeTitle.forSession(ComposeIntent.NEW, resumedFromServer = false),
        )
    }

    @Test
    fun `replies and reply-alls share one caption`() {
        assertEquals(
            ComposeTitleKind.REPLY,
            ComposeTitle.forSession(ComposeIntent.REPLY, resumedFromServer = false),
        )
        assertEquals(
            ComposeTitleKind.REPLY,
            ComposeTitle.forSession(ComposeIntent.REPLY_ALL, resumedFromServer = false),
        )
    }

    @Test
    fun `a forward keeps its own caption`() {
        assertEquals(
            ComposeTitleKind.FORWARD,
            ComposeTitle.forSession(ComposeIntent.FORWARD, resumedFromServer = false),
        )
    }

    @Test
    fun `a resumed draft reads as a draft, not as a new message`() {
        // DraftResume seeds NEW deliberately — that decides quoting, and it
        // is exactly why the intent alone could not answer this question.
        assertEquals(
            ComposeTitleKind.DRAFT,
            ComposeTitle.forSession(ComposeIntent.NEW, resumedFromServer = true),
        )
    }

    @Test
    fun `resuming wins over every intent`() {
        ComposeIntent.entries.forEach { intent ->
            assertEquals(
                ComposeTitleKind.DRAFT,
                ComposeTitle.forSession(intent, resumedFromServer = true),
                "resumed $intent",
            )
        }
    }
}
