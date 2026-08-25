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
    fun `band merge places envelopes at their offset and leaves gaps for missing uids`() {
        val merged =
            mergeBand(
                envelopes = window(10, 11),
                offset = 2,
                uids = listOf(12L, 13L, 14L),
                byUid = mapOf(12L to Envelope(id = 12), 14L to Envelope(id = 14)),
            )
        assertEquals(
            mapOf(0 to 10L, 1 to 11L, 2 to 12L, 4 to 14L),
            merged.mapValues { it.value.id },
        )
    }

    @Test
    fun `band merge evicts a stale copy of a uid the band re-places`() {
        // The folder shifted underneath the window: uid 11 used to sit at
        // index 1 and the refetched band now places it at index 0. The stale
        // entry must go, or the UID-keyed list would see a duplicate key.
        val merged =
            mergeBand(
                envelopes = window(10, 11, 12),
                offset = 0,
                uids = listOf(11L, 12L),
                byUid = mapOf(11L to Envelope(id = 11), 12L to Envelope(id = 12)),
            )
        assertEquals(
            mapOf(0 to 11L, 1 to 12L),
            merged.mapValues { it.value.id },
        )
    }

    @Test
    fun `refetched server copy wins over the loaded window`() {
        // The window still shows a star another client already cleared.
        val fetched = mapOf(1L to Envelope(id = 1, flags = emptyList()))
        val window = listOf(Envelope(id = 1, flags = listOf("\\Flagged")))
        val byUid = shieldPendingWrites(fetched, window) { false }
        assertEquals(emptyList<String>(), byUid[1L]?.flags)
    }

    @Test
    fun `rows with an in-flight flag write keep their optimistic copy`() {
        val fetched = mapOf(1L to Envelope(id = 1), 2L to Envelope(id = 2))
        val window =
            listOf(
                Envelope(id = 1, flags = listOf("\\Flagged")),
                Envelope(id = 2, flags = listOf("\\Flagged")),
            )
        val byUid = shieldPendingWrites(fetched, window) { it == 1L }
        assertEquals(listOf("\\Flagged"), byUid[1L]?.flags)
        assertEquals(emptyList<String>(), byUid[2L]?.flags)
    }

    @Test
    fun `shield never adds window rows absent from the fetched band`() {
        val fetched = mapOf(1L to Envelope(id = 1))
        val window = listOf(Envelope(id = 99, flags = listOf("\\Flagged")))
        val byUid = shieldPendingWrites(fetched, window) { true }
        assertEquals(setOf(1L), byUid.keys)
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
    fun `filtered rows read the window under ALL and the search matches under a pill`() {
        // The pills are server-backed (`/search_envelopes`), so they never
        // narrow the loaded window — that is `filterMatches`' job; ALL still
        // walks the window in display order for reader auto-advance.
        val state =
            MessageListUiState(
                envelopes =
                    mapOf(
                        0 to Envelope(id = 1, flags = listOf("\\Seen")),
                        1 to Envelope(id = 2),
                    ),
                filterMatches =
                    listOf(
                        Envelope(id = 9),
                        Envelope(id = 8, flags = listOf("\\Seen", "\\Flagged")),
                    ),
                filter = MessageFilter.ALL,
            )
        assertEquals(listOf(1L, 2L), state.filteredRows.map { it.id })
        assertEquals(
            listOf(9L),
            state.copy(filter = MessageFilter.UNREAD).filteredRows.map { it.id },
        )
        assertEquals(
            listOf(8L),
            state.copy(filter = MessageFilter.FLAGGED).filteredRows.map { it.id },
        )
    }
}
