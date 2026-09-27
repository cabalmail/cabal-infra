package com.cabalmail.android

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

/**
 * #1734: the Mail tab's folder rail and the Folders screen held independent
 * folder state and neither invalidated the other, so a folder created on one
 * took 30-60 s to reach the other, a deleted one stayed in the rail as a row
 * that opened on `Could not load messages (server error)`, and a folder
 * emptied in the Mail tab kept its old count on the Folders screen — which
 * hides the delete affordance, because deleting is gated on the folder being
 * empty.
 */
class FolderStateInvalidationTest {
    @Test
    fun `a folder set change makes a folder list stale`() {
        assertTrue(FolderStateInvalidation.listIsStale(MailEvent.FolderListChanged("Archive")))
    }

    @Test
    fun `message-level events leave the folder list alone`() {
        assertFalse(FolderStateInvalidation.listIsStale(MailEvent.Removed("INBOX", setOf(1L))))
        assertFalse(FolderStateInvalidation.listIsStale(MailEvent.Reconcile("INBOX")))
        assertFalse(
            FolderStateInvalidation.listIsStale(
                MailEvent.FlagChanged("INBOX", setOf(1L), "\\Seen", true),
            ),
        )
    }

    @Test
    fun `messages leaving a folder make that folder's count stale`() {
        assertEquals(
            setOf("Archive"),
            FolderStateInvalidation.staleCountFolders(MailEvent.Removed("Archive", setOf(1L))),
        )
        assertEquals(setOf("Archive"), FolderStateInvalidation.staleCountFolders(MailEvent.Reconcile("Archive")))
    }

    @Test
    fun `a move makes the destination's count stale as well as the source's`() {
        assertEquals(
            setOf("INBOX", "Trash"),
            FolderStateInvalidation.staleCountFolders(MailEvent.Removed("INBOX", setOf(1L), "Trash")),
        )
    }

    @Test
    fun `a flag write does not move the count the Folders screen shows`() {
        assertEquals(
            emptySet<String>(),
            FolderStateInvalidation.staleCountFolders(
                MailEvent.FlagChanged("INBOX", setOf(1L), "\\Seen", true),
            ),
        )
        assertEquals(
            emptySet<String>(),
            FolderStateInvalidation.staleCountFolders(MailEvent.FolderListChanged("INBOX")),
        )
    }

    /**
     * The policy only pays if the mutations announce themselves and the two
     * folder lists listen. Neither running screen has a unit-test seam here
     * (both need a live [AppContainer]), so the source carries the rule — the
     * same shape as `DisposeSurfaceScanTest`. Gradle runs unit tests from the
     * module directory, so the repository root is two levels up.
     */
    private val mainSources: File =
        File(File("../..").canonicalFile, "android/app/src/main/kotlin/com/cabalmail/android")

    private fun code(path: String): String =
        File(mainSources, path)
            .readText()
            .replace(Regex("""(?s)/\*.*?\*/"""), "")
            .lines()
            .joinToString("\n") { it.substringBefore("//") }

    @Test
    fun `every folder set mutation announces itself`() {
        val admin = code("ui/folders/FoldersAdminViewModel.kt")
        val announcements = Regex("""MailEvent\.FolderListChanged\(""").findAll(admin).count()
        // create, delete and subscribe/unsubscribe: the three mutations the
        // Folders screen makes to the set the rail draws.
        assertEquals(3, announcements, "a Folders-screen mutation that the rail never hears about")
    }

    @Test
    fun `every message movement announces itself`() {
        val list = code("ui/mail/MessageListViewModel.kt")
        // move and purge: the message list applies both to its own rows, and
        // used to tell the Folders screen's counts nothing.
        assertEquals(
            2,
            Regex("""MailEvent\.Removed\(""").findAll(list).count(),
            "a message list mutation the Folders screen never hears about",
        )
        val reader = code("ui/mail/MessageDetailViewModel.kt")
        assertTrue(
            reader.contains("MailEvent.Removed(folder, setOf(uid), destination)"),
            "the reader's disposals no longer name where the message landed",
        )
    }

    @Test
    fun `a count refetch waits for the optimistic write to settle`() {
        // Only inside reloadCount: the whole-map load has no write to wait on.
        val reload =
            code("ui/folders/FoldersAdminViewModel.kt")
                .substringAfter("private fun reloadCount")
        val await = reload.indexOf("awaitWritesSettled()")
        val status = reload.indexOf("folderStatus(")
        assertTrue(await in 0 until status, "the count STATUS can race the write it is answering")
    }

    @Test
    fun `both folder lists reload off the bus`() {
        assertTrue(
            code("ui/mail/FoldersViewModel.kt").contains("FolderStateInvalidation.listIsStale"),
            "the Mail tab's rail is back to waiting for its own poll",
        )
        assertTrue(
            code("ui/folders/FoldersAdminViewModel.kt").contains("FolderStateInvalidation.staleCountFolders"),
            "the Folders screen is back to waiting for a pull-to-refresh",
        )
    }
}
