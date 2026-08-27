package com.cabalmail.android.ui.compose

import com.cabalmail.android.MailEvent
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * The rule behind [DraftsMutationEvent] (#1290): which of the two mail
 * events a compose session owes an open Drafts list, given what its
 * `/save_draft` or `/send` round trip actually did to the folder.
 *
 * The distinction that matters is optimistic-vs-refetch. A row the list
 * already holds can be dropped on the spot; a row it has never seen, or a
 * removal the server declined, cannot be — dropping the latter would show
 * the user a deletion that did not happen.
 */
class DraftsMutationEventTest {
    @Test
    fun `a discard the server honoured removes exactly that uid`() {
        assertEquals(
            MailEvent.Removed("Drafts", setOf(853L)),
            DraftsMutationEvent.forDraftsChange(removedUid = 853L, appended = false),
        )
    }

    @Test
    fun `a discard the server declined refetches instead of dropping the row`() {
        assertEquals(
            MailEvent.Reconcile("Drafts"),
            DraftsMutationEvent.forDraftsChange(removedUid = null, appended = false),
        )
    }

    @Test
    fun `a save refetches, because the appended copy is a row the list has never seen`() {
        assertEquals(
            MailEvent.Reconcile("Drafts"),
            DraftsMutationEvent.forDraftsChange(removedUid = null, appended = true),
        )
    }

    @Test
    fun `a replacing save refetches too, even though it names the copy it retired`() {
        // The retired uid alone would leave the list a row short: the same
        // call appended the replacement, so only a refetch is honest.
        assertEquals(
            MailEvent.Reconcile("Drafts"),
            DraftsMutationEvent.forDraftsChange(removedUid = 853L, appended = true),
        )
    }

    @Test
    fun `every outcome is scoped to Drafts`() {
        val outcomes =
            listOf(
                DraftsMutationEvent.forDraftsChange(removedUid = 1L, appended = false),
                DraftsMutationEvent.forDraftsChange(removedUid = null, appended = false),
                DraftsMutationEvent.forDraftsChange(removedUid = null, appended = true),
                DraftsMutationEvent.forDraftsChange(removedUid = 1L, appended = true),
            )
        outcomes.forEach { assertEquals("Drafts", it.folder) }
    }
}
