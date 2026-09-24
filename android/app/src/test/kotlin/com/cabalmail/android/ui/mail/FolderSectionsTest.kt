package com.cabalmail.android.ui.mail

import com.cabalmail.kit.models.FolderStatus
import com.cabalmail.kit.settings.AppPreferences
import com.cabalmail.kit.settings.FolderCountDisplay
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class FolderSectionsTest {
    private val folders = listOf("INBOX", "Archive", "Drafts", "Sent", "Trash", "receipts")
    private val subscribed = setOf("INBOX", "Trash", "Sent")
    private val statuses =
        mapOf(
            "INBOX" to FolderStatus(messages = 40, unseen = 3),
            "Sent" to FolderStatus(messages = 10, unseen = 0),
            "receipts" to FolderStatus(messages = 5, unseen = 1),
        )

    @Test
    fun `the default filter is Subscribed on, Unread off`() {
        val filter = FolderListFilter()
        assertTrue(filter.subscribed)
        assertFalse(filter.unread)
        assertFalse(filter.isAll)
        assertTrue(filter.isOn(FolderFilterPill.SUBSCRIBED))
        assertFalse(filter.isOn(FolderFilterPill.UNREAD))
        assertFalse(filter.isOn(FolderFilterPill.ALL))
    }

    @Test
    fun `All is on exactly when both toggles are off`() {
        val all = FolderListFilter(subscribed = false, unread = false)
        assertTrue(all.isAll)
        assertTrue(all.isOn(FolderFilterPill.ALL))
        assertFalse(FolderListFilter(subscribed = false, unread = true).isAll)
        assertFalse(FolderListFilter(subscribed = true, unread = true).isAll)
    }

    @Test
    fun `tapping Subscribed or Unread flips only that toggle`() {
        val filter = FolderListFilter(subscribed = true, unread = false)
        assertEquals(FolderListFilter(subscribed = false, unread = false), filter.toggled(FolderFilterPill.SUBSCRIBED))
        assertEquals(FolderListFilter(subscribed = true, unread = true), filter.toggled(FolderFilterPill.UNREAD))
        assertEquals(filter, filter.toggled(FolderFilterPill.UNREAD).toggled(FolderFilterPill.UNREAD))
    }

    @Test
    fun `tapping All clears both toggles`() {
        val filter = FolderListFilter(subscribed = true, unread = true)
        assertEquals(FolderListFilter(subscribed = false, unread = false), filter.toggled(FolderFilterPill.ALL))
        assertTrue(FolderListFilter().toggled(FolderFilterPill.ALL).isAll)
    }

    @Test
    fun `only Unread without Subscribed needs every folder's status`() {
        assertTrue(FolderListFilter(subscribed = false, unread = true).needsAllStatuses)
        assertFalse(FolderListFilter(subscribed = true, unread = true).needsAllStatuses)
        assertFalse(FolderListFilter(subscribed = false, unread = false).needsAllStatuses)
        assertFalse(FolderListFilter().needsAllStatuses)
    }

    @Test
    fun `the filter reads back from the per-device preferences`() {
        assertEquals(FolderListFilter(), AppPreferences().folderListFilter)
        assertEquals(
            FolderListFilter(subscribed = false, unread = true),
            AppPreferences(folderFilterSubscribed = false, folderFilterUnread = true).folderListFilter,
        )
    }

    @Test
    fun `All shows every folder in server order`() {
        assertEquals(
            folders,
            FolderSections.rows(folders, subscribed, statuses, FolderListFilter(false, false), selected = null),
        )
    }

    @Test
    fun `Subscribed keeps server order and drops the rest`() {
        assertEquals(
            listOf("INBOX", "Sent", "Trash"),
            FolderSections.rows(folders, subscribed, statuses, FolderListFilter(subscribed = true), selected = null),
        )
    }

    @Test
    fun `Unread alone keeps folders with unseen mail whether subscribed or not`() {
        assertEquals(
            listOf("INBOX", "receipts"),
            FolderSections.rows(folders, subscribed, statuses, FolderListFilter(false, true), selected = null),
        )
    }

    @Test
    fun `Subscribed and Unread together intersect`() {
        assertEquals(
            listOf("INBOX"),
            FolderSections.rows(folders, subscribed, statuses, FolderListFilter(true, true), selected = null),
        )
    }

    @Test
    fun `the selected folder is always kept`() {
        assertEquals(
            listOf("INBOX", "Sent"),
            FolderSections.rows(folders, subscribed, statuses, FolderListFilter(true, true), selected = "Sent"),
        )
        assertEquals(
            listOf("INBOX", "Drafts", "Sent", "Trash"),
            FolderSections.rows(
                folders,
                subscribed,
                statuses,
                FolderListFilter(subscribed = true),
                selected = "Drafts",
            ),
        )
    }

    @Test
    fun `a subscription naming no listed folder yields no rows`() {
        assertEquals(
            emptyList<String>(),
            FolderSections.rows(folders, setOf("gone"), statuses, FolderListFilter(subscribed = true), selected = null),
        )
    }

    @Test
    fun `proactive status is scoped to subscribed folders`() {
        assertEquals(
            listOf("INBOX", "Sent", "Trash"),
            FolderSections.statusTargets(folders, subscribed),
        )
    }

    @Test
    fun `includeAll widens the status walk to every folder`() {
        assertEquals(folders, FolderSections.statusTargets(folders, subscribed, includeAll = true))
    }

    @Test
    fun `without subscription data every folder keeps its badge`() {
        assertEquals(folders, FolderSections.statusTargets(folders, emptySet()))
    }

    @Test
    fun `only a known positive unseen count highlights the name`() {
        assertTrue(FolderSections.hasUnread(FolderStatus(messages = 40, unseen = 3)))
        assertFalse(FolderSections.hasUnread(FolderStatus(messages = 40, unseen = 0)))
    }

    @Test
    fun `an unknown status rests dim, not highlighted`() {
        assertFalse(FolderSections.hasUnread(null))
        assertFalse(FolderSections.hasUnread(FolderStatus(messages = 40)))
    }

    @Test
    fun `the badge shows unread, total, or both, and hides a zero`() {
        assertEquals("3", FolderSections.badge(FolderCountDisplay.UNREAD, unread = 3, total = 40))
        assertEquals(null, FolderSections.badge(FolderCountDisplay.UNREAD, unread = 0, total = 40))
        assertEquals("40", FolderSections.badge(FolderCountDisplay.TOTAL, unread = 3, total = 40))
        assertEquals(null, FolderSections.badge(FolderCountDisplay.TOTAL, unread = 3, total = 0))
        assertEquals("3 / 40", FolderSections.badge(FolderCountDisplay.BOTH, unread = 3, total = 40))
        assertEquals("0 / 40", FolderSections.badge(FolderCountDisplay.BOTH, unread = 0, total = 40))
        assertEquals(null, FolderSections.badge(FolderCountDisplay.BOTH, unread = 0, total = 0))
    }

    @Test
    fun `switch menu lists subscribed folders first and the rest in the submenu`() {
        assertEquals(
            FolderSwitchMenu(
                primary = listOf("INBOX", "Sent", "Trash"),
                other = listOf("Archive", "Drafts", "receipts"),
            ),
            FolderSections.switchMenu(folders, subscribed),
        )
    }

    @Test
    fun `switch menu with nothing subscribed lists everything at the top level`() {
        assertEquals(
            FolderSwitchMenu(primary = folders, other = emptyList()),
            FolderSections.switchMenu(folders, emptySet()),
        )
    }

    @Test
    fun `switch menu has no submenu when everything is subscribed`() {
        assertEquals(
            FolderSwitchMenu(primary = folders, other = emptyList()),
            FolderSections.switchMenu(folders, folders.toSet()),
        )
    }
}
