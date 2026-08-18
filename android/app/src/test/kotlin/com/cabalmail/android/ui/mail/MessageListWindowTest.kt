package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.Envelope
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class MessageListWindowTest {
    private fun window(vararg uids: Long): Map<Int, Envelope> =
        uids.withIndex().associate { (index, uid) -> index to Envelope(id = uid) }

    @Test
    fun `compaction drops removed uids and shifts higher indices down`() {
        val compacted = compactWindow(window(10, 11, 12, 13), removed = setOf(11L))
        assertEquals(
            mapOf(0 to 10L, 1 to 12L, 2 to 13L),
            compacted.mapValues { it.value.id },
        )
    }

    @Test
    fun `compaction handles multiple removals and sparse windows`() {
        // A sparse window (band gap between 1 and 10) with two removals.
        val sparse =
            mapOf(
                0 to Envelope(id = 20),
                1 to Envelope(id = 21),
                10 to Envelope(id = 30),
                11 to Envelope(id = 31),
            )
        val compacted = compactWindow(sparse, removed = setOf(20L, 30L))
        assertEquals(
            mapOf(0 to 21L, 9 to 31L),
            compacted.mapValues { it.value.id },
        )
    }

    @Test
    fun `compaction with no matching uids is a no-op`() {
        val original = window(1, 2, 3)
        assertEquals(original, compactWindow(original, removed = setOf(99L)))
    }

    @Test
    fun `pill counts track local flag mutations and clamp at zero`() {
        val counts = FolderCounts(all = 4, unseen = 2, flagged = 0)
        assertEquals(1, counts.adjustedFor("\\Seen", gained = 1).unseen)
        assertEquals(3, counts.adjustedFor("\\Seen", gained = -1).unseen)
        assertEquals(2, counts.adjustedFor("\\Flagged", gained = 2).flagged)
        assertEquals(0, counts.adjustedFor("\\Flagged", gained = -1).flagged)
        assertEquals(counts, counts.adjustedFor("\\Answered", gained = 1))
    }

    @Test
    fun `filter pills narrow the loaded window`() {
        val state =
            MessageListUiState(
                envelopes =
                    mapOf(
                        0 to Envelope(id = 1, flags = listOf("\\Seen")),
                        1 to Envelope(id = 2),
                        2 to Envelope(id = 3, flags = listOf("\\Seen", "\\Flagged")),
                    ),
                filter = MessageFilter.UNREAD,
            )
        assertEquals(listOf(2L), state.filteredRows.map { it.id })
        assertEquals(
            listOf(3L),
            state.copy(filter = MessageFilter.FLAGGED).filteredRows.map { it.id },
        )
        assertEquals(
            listOf(1L, 2L, 3L),
            state.copy(filter = MessageFilter.ALL).filteredRows.map { it.id },
        )
    }
}
