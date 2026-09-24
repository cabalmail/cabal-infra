package com.cabalmail.android.ui.mail

import com.cabalmail.kit.settings.DisposeAction
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** Mirrors the Apple clients' `DisposeIntentTests` reconciliation rules. */
class DisposeIntentTest {
    @Test
    fun `standard dispose in an ordinary folder follows the preference`() {
        assertEquals(
            DisposeIntent.Move(DisposeAction.ARCHIVE),
            DisposeIntent.standard(DisposeAction.ARCHIVE, "INBOX"),
        )
        assertEquals(
            DisposeIntent.Move(DisposeAction.TRASH),
            DisposeIntent.standard(DisposeAction.TRASH, "INBOX"),
        )
    }

    @Test
    fun `archiving inside Archive restores rather than archiving onto itself`() {
        assertEquals(DisposeIntent.Restore, DisposeIntent.standard(DisposeAction.ARCHIVE, "Archive"))
        assertEquals(DisposeIntent.Restore, DisposeIntent.explicit(DisposeAction.ARCHIVE, "Archive"))
    }

    @Test
    fun `trash preference inside Archive still trashes`() {
        assertEquals(
            DisposeIntent.Move(DisposeAction.TRASH),
            DisposeIntent.standard(DisposeAction.TRASH, "Archive"),
        )
    }

    @Test
    fun `inside Trash a standard dispose purges whichever way the preference points`() {
        assertEquals(DisposeIntent.Purge, DisposeIntent.standard(DisposeAction.ARCHIVE, "Trash"))
        assertEquals(DisposeIntent.Purge, DisposeIntent.standard(DisposeAction.TRASH, "Trash"))
    }

    @Test
    fun `a folder merely named like Archive is not Archive`() {
        assertEquals(
            DisposeIntent.Move(DisposeAction.ARCHIVE),
            DisposeIntent.standard(DisposeAction.ARCHIVE, "Archive.2024"),
        )
    }

    @Test
    fun `explicit archive inside Trash stays a real archive`() {
        assertEquals(
            DisposeIntent.Move(DisposeAction.ARCHIVE),
            DisposeIntent.explicit(DisposeAction.ARCHIVE, "Trash"),
        )
    }

    @Test
    fun `explicit trash reconciles to a purge only inside Trash`() {
        assertEquals(DisposeIntent.Purge, DisposeIntent.explicit(DisposeAction.TRASH, "Trash"))
        assertEquals(
            DisposeIntent.Move(DisposeAction.TRASH),
            DisposeIntent.explicit(DisposeAction.TRASH, "INBOX"),
        )
    }

    @Test
    fun `move destinations match the intent and never target the acting folder`() {
        assertEquals("Archive", DisposeIntent.Move(DisposeAction.ARCHIVE).destination)
        assertEquals("Trash", DisposeIntent.Move(DisposeAction.TRASH).destination)
        DisposeAction.entries.forEach { preference ->
            listOf("INBOX", "Archive", "Trash", "Drafts").forEach { folder ->
                val intent = DisposeIntent.standard(preference, folder)
                assertTrue((intent as? DisposeIntent.Move)?.destination != folder) {
                    "$preference in $folder resolved to a same-folder move"
                }
            }
        }
    }

    @Test
    fun `the move target carries the destination and the read flag together`() {
        // #1628: Search composed its own destination from the preference and
        // always marked the message read, so a result in Archive moved onto
        // Archive and came back marked read. Both halves live on the intent.
        assertEquals(
            DisposeIntent.MoveTarget("Archive", markSeen = true),
            DisposeIntent.Move(DisposeAction.ARCHIVE).moveTarget,
        )
        assertEquals(
            DisposeIntent.MoveTarget("Trash", markSeen = true),
            DisposeIntent.Move(DisposeAction.TRASH).moveTarget,
        )
        assertEquals(
            DisposeIntent.MoveTarget("INBOX", markSeen = false),
            DisposeIntent.Restore.moveTarget,
        )
        assertNull(DisposeIntent.Purge.moveTarget)
    }

    @Test
    fun `a standard dispose never moves a message onto the folder it is in`() {
        DisposeAction.entries.forEach { preference ->
            listOf("INBOX", "Archive", "Trash", "Drafts", "Sent").forEach { folder ->
                val target = DisposeIntent.standard(preference, folder).moveTarget
                assertTrue(target == null || target.destination != folder) {
                    "$preference in $folder resolved to a same-folder move"
                }
            }
        }
    }

    @Test
    fun `only trash-bound intents read as destructive`() {
        assertTrue(DisposeIntent.Purge.isDestructive)
        assertTrue(DisposeIntent.Move(DisposeAction.TRASH).isDestructive)
        assertFalse(DisposeIntent.Move(DisposeAction.ARCHIVE).isDestructive)
        assertFalse(DisposeIntent.Restore.isDestructive)
    }
}
