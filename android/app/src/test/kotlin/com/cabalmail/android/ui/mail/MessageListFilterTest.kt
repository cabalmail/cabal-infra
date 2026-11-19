package com.cabalmail.android.ui.mail

import com.cabalmail.android.R
import com.cabalmail.android.ui.theme.UiLabel
import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.SearchFilters
import com.cabalmail.kit.settings.FlagCriterion
import com.cabalmail.kit.settings.FlagPalette
import com.cabalmail.kit.settings.FlagPaletteEntry
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
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

    private val later = "cabal-flag-01"
    private val work = "cabal-flag-02"

    @Test
    fun `a picked flag keeps only the matches that still carry it`() {
        val matches =
            listOf(envelope(4, later, "\\Flagged"), envelope(3, work), envelope(2, "\\Seen", later), envelope(1))
        val state = MessageListUiState(filter = MessageFilter.UNREAD, filterMatches = matches)

        assertEquals(listOf(4L, 2L), state.copy(flagPick = FlagCriterion.Slot(later)).filteredRows.map { it.id })
        assertEquals(
            listOf(4L, 3L, 2L),
            state.copy(flagPick = FlagCriterion.AnyFlag).filteredRows.map { it.id },
            "the remembered Unread pill does not narrow a pick",
        )
        assertEquals(listOf(4L, 3L, 1L), state.filteredRows.map { it.id }, "and comes back when the pick ends")
    }

    @Test
    fun `a pick takes the list over without changing the pill the folder remembers`() {
        val remembered = MessageListUiState(filter = MessageFilter.FLAGGED)
        val picked = remembered.copy(flagPick = FlagCriterion.Slot(later))

        assertTrue(remembered.builtInFlagLit)
        assertFalse(picked.builtInFlagLit, "the built-in flag is not what the list shows")
        assertEquals(MessageFilter.FLAGGED, picked.filter)
        assertFalse(MessageListUiState(filter = MessageFilter.UNREAD, flagPick = FlagCriterion.AnyFlag).unreadLit)
        assertTrue(MessageListUiState(filter = MessageFilter.UNREAD).unreadLit)

        assertTrue(MessageListUiState().showsAll)
        assertFalse(MessageListUiState(flagPick = FlagCriterion.AnyFlag).showsAll, "a pick is a search, not the folder")
        assertFalse(MessageListUiState(filter = MessageFilter.UNREAD).showsAll)
    }

    @Test
    fun `a flag of the user's own is searched as keyword alone, and Any flag as any_flag alone`() {
        val unread = MessageListUiState(filter = MessageFilter.UNREAD)
        val flagged = MessageListUiState(filter = MessageFilter.FLAGGED)

        assertEquals(SearchFilters(unread = true), unread.pillSearch)
        assertEquals(SearchFilters(flagged = true), flagged.pillSearch)
        assertEquals(SearchFilters(keyword = later), flagged.copy(flagPick = FlagCriterion.Slot(later)).pillSearch)
        assertEquals(SearchFilters(keyword = work), unread.copy(flagPick = FlagCriterion.Slot(work)).pillSearch)
        assertEquals(SearchFilters(anyFlag = true), unread.copy(flagPick = FlagCriterion.AnyFlag).pillSearch)
        // The built-in flag is never sent as a keyword: the server refuses it there.
        assertEquals(
            SearchFilters(flagged = true),
            unread.copy(flagPick = FlagCriterion.Slot(FlagPalette.SYSTEM_SLOT)).pillSearch,
        )
    }

    @Test
    fun `Unread tapped over a pick is a choice of Unread, whatever the folder remembered`() {
        val pick = FlagCriterion.Slot(later)

        assertEquals(MessageFilter.UNREAD, unreadTap(MessageFilter.UNREAD, pick), "not a toggle back to All")
        assertEquals(MessageFilter.UNREAD, unreadTap(MessageFilter.FLAGGED, pick))
        assertEquals(MessageFilter.UNREAD, unreadTap(MessageFilter.ALL, FlagCriterion.AnyFlag))
        assertEquals(MessageFilter.ALL, unreadTap(MessageFilter.UNREAD, pick = null), "the toggle it always was")
        assertEquals(MessageFilter.UNREAD, unreadTap(MessageFilter.FLAGGED, pick = null))
    }

    @Test
    fun `a pick that finds nothing names the flag it looked for`() {
        val palette = listOf(FlagPaletteEntry(slot = later, label = "Later", color = "blue"))

        assertEquals(UiLabel.Fixed(R.string.filter_no_matches), pillEmptyWords(null, palette))
        assertEquals(
            UiLabel.Formatted(R.string.filter_no_matches_flag, "Later"),
            pillEmptyWords(FlagCriterion.Slot(later), palette),
        )
        assertEquals(UiLabel.Fixed(R.string.filter_no_matches_any_flag), pillEmptyWords(FlagCriterion.AnyFlag, palette))
        assertEquals(
            UiLabel.Formatted(R.string.filter_no_matches_flag, work),
            pillEmptyWords(FlagCriterion.Slot(work), palette),
            "a flag deleted while it was picked is named by its slot",
        )
    }

    @Test
    fun `the filter pills are toggles with no All pill`() {
        assertEquals(listOf(MessageFilter.UNREAD, MessageFilter.FLAGGED), MessageFilter.PILLS)
        assertEquals(MessageFilter.UNREAD, MessageFilter.ALL.toggling(MessageFilter.UNREAD))
        assertEquals(MessageFilter.ALL, MessageFilter.UNREAD.toggling(MessageFilter.UNREAD))
        assertEquals(MessageFilter.ALL, MessageFilter.FLAGGED.toggling(MessageFilter.FLAGGED))
        assertEquals(MessageFilter.FLAGGED, MessageFilter.UNREAD.toggling(MessageFilter.FLAGGED))
    }
}
