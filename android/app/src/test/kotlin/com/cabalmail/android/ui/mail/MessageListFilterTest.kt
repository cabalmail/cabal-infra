package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.Envelope
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * The filter pill's server-backed match list: page appends (cursor paging
 * over `/search_envelopes`) and the client-side re-narrowing that drops a
 * row the moment it stops matching.
 */
class MessageListFilterTest {
    private fun envelope(
        uid: Long,
        vararg flags: String,
    ): Envelope = Envelope(id = uid, flags = flags.toList())

    @Test
    fun `page append keeps order and drops uids already present`() {
        // The date-based cursor can re-deliver the previous page's boundary
        // row after mailbox churn; the duplicate must not become a duplicate
        // key for the UID-keyed list.
        val appended =
            appendFilterPage(
                matches = listOf(envelope(30), envelope(20)),
                page = listOf(envelope(20), envelope(10)),
            )
        assertEquals(listOf(30L, 20L, 10L), appended.map { it.id })
    }

    @Test
    fun `page append onto empty is the page itself`() {
        val appended = appendFilterPage(emptyList(), listOf(envelope(2), envelope(1)))
        assertEquals(listOf(2L, 1L), appended.map { it.id })
    }

    @Test
    fun `unread pill drops a match once it is marked read`() {
        val state =
            MessageListUiState(
                filter = MessageFilter.UNREAD,
                filterMatches = listOf(envelope(3), envelope(2, "\\Seen"), envelope(1)),
            )
        assertEquals(listOf(3L, 1L), state.filteredRows.map { it.id })
    }

    @Test
    fun `flagged pill keeps only flagged matches`() {
        val state =
            MessageListUiState(
                filter = MessageFilter.FLAGGED,
                filterMatches = listOf(envelope(3, "\\Flagged"), envelope(2, "\\Seen")),
            )
        assertEquals(listOf(3L), state.filteredRows.map { it.id })
    }
}
