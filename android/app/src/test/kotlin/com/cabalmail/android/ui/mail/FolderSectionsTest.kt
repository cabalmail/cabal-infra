package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class FolderSectionsTest {
    private val folders = listOf("INBOX", "Archive", "Drafts", "Sent", "Trash", "receipts")
    private val subscribed = setOf("INBOX", "Trash", "Sent")

    @Test
    fun `sections appear only when something is subscribed`() {
        assertTrue(FolderSections.sectioned(subscribed))
        assertFalse(FolderSections.sectioned(emptySet()))
    }

    @Test
    fun `subscribed rows keep server order and drop the rest`() {
        assertEquals(
            listOf("INBOX", "Sent", "Trash"),
            FolderSections.subscribedRows(folders, subscribed),
        )
    }

    @Test
    fun `a subscription naming no listed folder yields no rows`() {
        assertEquals(
            emptyList<String>(),
            FolderSections.subscribedRows(folders, setOf("gone")),
        )
    }

    @Test
    fun `a collapsed section draws nothing, an expanded one everything`() {
        assertEquals(emptyList<String>(), FolderSections.visibleRows(folders, isExpanded = false))
        assertEquals(folders, FolderSections.visibleRows(folders, isExpanded = true))
    }

    @Test
    fun `chevron points right collapsed and down expanded`() {
        assertEquals(0f, FolderSections.chevronRotation(isExpanded = false))
        assertEquals(90f, FolderSections.chevronRotation(isExpanded = true))
    }

    @Test
    fun `proactive status is scoped to subscribed folders`() {
        assertEquals(
            listOf("INBOX", "Sent", "Trash"),
            FolderSections.statusTargets(folders, subscribed),
        )
    }

    @Test
    fun `without subscription data every folder keeps its badge`() {
        assertEquals(folders, FolderSections.statusTargets(folders, emptySet()))
    }
}
