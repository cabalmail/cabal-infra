package com.cabalmail.android.ui.settings

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class PushFolderScopeTest {
    @Test
    fun `empty set is the inbox-only default`() {
        assertEquals(PushFolderScope.InboxOnly, PushFolderScope.of(emptySet()))
    }

    @Test
    fun `a star anywhere means all folders`() {
        assertEquals(PushFolderScope.All, PushFolderScope.of(setOf("*")))
        assertEquals(PushFolderScope.All, PushFolderScope.of(setOf("INBOX", "*")))
    }

    @Test
    fun `anything else is exact membership`() {
        assertEquals(
            PushFolderScope.Custom(setOf("INBOX", "Receipts")),
            PushFolderScope.of(setOf("INBOX", "Receipts")),
        )
    }

    @Test
    fun `wire round-trips each scope`() {
        assertEquals(emptySet<String>(), pushFoldersFor(PushFolderScope.InboxOnly))
        assertEquals(setOf("*"), pushFoldersFor(PushFolderScope.All))
        assertEquals(
            setOf("INBOX", "Receipts"),
            pushFoldersFor(PushFolderScope.Custom(setOf("INBOX", "Receipts"))),
        )
    }

    @Test
    fun `custom with nothing checked collapses to the default`() {
        // The wire encodes both identically; the classifier must agree.
        val stored = pushFoldersFor(PushFolderScope.Custom(emptySet()))

        assertEquals(PushFolderScope.InboxOnly, PushFolderScope.of(stored))
    }
}
