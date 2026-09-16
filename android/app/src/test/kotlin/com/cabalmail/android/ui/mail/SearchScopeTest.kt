package com.cabalmail.android.ui.mail

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * Where a completed search looked (#1608). "No messages found" for mail that
 * is only in Sent read as "it does not exist"; the scope is what tells an
 * exhausted search from an unasked one. Pure, no Compose.
 */
class SearchScopeTest {
    @Test
    fun `a cross-folder search names the folders the server reported`() {
        assertEquals(
            SearchScope.Folders(listOf("INBOX", "Archive"), more = 0),
            searchScope(listOf("INBOX", "Archive"), folderOnly = false, anchorFolder = "INBOX"),
        )
    }

    @Test
    fun `past three folders the rest are counted, not named`() {
        assertEquals(
            SearchScope.Folders(listOf("INBOX", "Archive", "Lists"), more = 2),
            searchScope(
                listOf("INBOX", "Archive", "Lists", "Receipts", "Travel"),
                folderOnly = false,
                anchorFolder = null,
            ),
        )
        assertEquals(
            SearchScope.Folders(listOf("INBOX", "Archive", "Lists"), more = 0),
            searchScope(listOf("INBOX", "Archive", "Lists"), folderOnly = false, anchorFolder = null),
        )
    }

    @Test
    fun `a folder-only search names its folder, from the server when it reported one`() {
        assertEquals(
            SearchScope.FolderOnly("Archive"),
            searchScope(listOf("Archive"), folderOnly = true, anchorFolder = "INBOX"),
        )
        assertEquals(
            SearchScope.FolderOnly("INBOX"),
            searchScope(emptyList(), folderOnly = true, anchorFolder = "INBOX"),
        )
    }

    @Test
    fun `nothing is claimed when the scope is unknown`() {
        // "All folders" would be false: unsubscribed folders and Trash are never searched.
        assertNull(searchScope(emptyList(), folderOnly = false, anchorFolder = "INBOX"))
        assertNull(searchScope(emptyList(), folderOnly = true, anchorFolder = null))
    }
}
