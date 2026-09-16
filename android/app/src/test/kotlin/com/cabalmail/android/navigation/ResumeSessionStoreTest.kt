package com.cabalmail.android.navigation

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/**
 * The per-install session record (resume-session plan, Phase B): recording
 * in call order with identity-guarded clears, the launch snapshot frozen
 * against the live record, persistence across a reopen, and sign-out.
 *
 * The store's actor and writer are launched on the test scope itself and
 * closed in `finally` — this coroutines-test version does not advance
 * `backgroundScope` jobs under `advanceUntilIdle`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ResumeSessionStoreTest {
    @TempDir
    lateinit var dir: File

    private fun TestScope.open(file: File): ResumeSessionStore {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return ResumeSessionStore(file, this, io = dispatcher, debounceMs = 10, now = { 1_757_000_000_000 })
    }

    private fun storeTest(
        name: String = "resume-session.json",
        block: suspend TestScope.(ResumeSessionStore, File) -> Unit,
    ) = runTest {
        val file = File(dir, name)
        val store = open(file)
        try {
            block(store, file)
        } finally {
            store.close()
        }
    }

    @Test
    fun `an empty install lands on mail with nothing saved`() =
        storeTest { store, _ ->
            assertNull(store.launchSnapshot())
            assertEquals(ResumeSession(), store.current())
        }

    @Test
    fun `mail recording keeps the feed position and vice versa`() =
        storeTest { store, _ ->
            store.recordFolder("INBOX")
            store.recordMessage("INBOX", 316, "<316@x>")
            store.recordFeedScope("sub:s1")
            store.recordFeedItem("f1#k1")
            advanceUntilIdle()
            val session = store.current()
            assertEquals(ResumeSection.FEEDS, session.section)
            assertEquals("INBOX", session.folder)
            assertEquals(316L, session.uid)
            assertEquals("<316@x>", session.messageId)
            assertEquals("sub:s1", session.feedScope)
            assertEquals("f1#k1", session.feedItemId)

            store.recordFolder("Archive")
            advanceUntilIdle()
            val moved = store.current()
            assertEquals(ResumeSection.MAIL, moved.section)
            assertEquals("Archive", moved.folder)
            assertFalse(moved.hasMessage, "a folder pick clears the open message")
            assertEquals("sub:s1", moved.feedScope, "the feed position is kept for a round trip")
            assertEquals("f1#k1", moved.feedItemId)
        }

    @Test
    fun `clears are guarded by identity`() =
        storeTest { store, _ ->
            store.recordMessage("INBOX", 5, "<five>")
            // On a wide window the next reader's model is created before the
            // previous one is cleared: the stale clear must not win.
            store.recordMessage("INBOX", 6, "<six>")
            store.recordNoMessage("INBOX", 5)
            advanceUntilIdle()
            assertEquals(6L, store.current().uid)
            store.recordNoMessage("INBOX", 6)
            advanceUntilIdle()
            assertFalse(store.current().hasMessage)

            store.recordFeedScope("all")
            store.recordFeedItem("f1#a")
            store.recordFeedItem("f1#b")
            store.recordNoFeedItem("f1#a")
            advanceUntilIdle()
            assertEquals("f1#b", store.current().feedItemId)
            store.recordNoFeedItem("f1#b")
            advanceUntilIdle()
            assertNull(store.current().feedItemId)
            assertEquals("all", store.current().feedScope, "back to the list keeps the scope")
        }

    @Test
    fun `back to the feed tree clears the scope but keeps the section`() =
        storeTest { store, _ ->
            store.recordFeedScope("folder:fo")
            store.recordFeedScope(null)
            advanceUntilIdle()
            val session = store.current()
            assertEquals(ResumeSection.FEEDS, session.section)
            assertNull(session.feedScope)
        }

    @Test
    fun `noteSection moves only the section`() =
        storeTest { store, _ ->
            store.recordMessage("Lists", 1, null)
            store.recordFeedScope("all")
            store.noteSection(ResumeSection.MAIL)
            advanceUntilIdle()
            val session = store.current()
            assertEquals(ResumeSection.MAIL, session.section)
            assertEquals("Lists", session.folder)
            assertEquals(1L, session.uid)
            assertEquals("all", session.feedScope)
        }

    @Test
    fun `the record persists and reopens, and the launch snapshot stays frozen`() =
        storeTest { first, file ->
            first.recordFolder("INBOX")
            first.recordMessage("INBOX", 316, "<316@x>")
            first.recordFeedScope("sub:s1")
            first.noteSection(ResumeSection.FEEDS)
            advanceUntilIdle()
            assertTrue(file.exists())

            val second = open(file)
            try {
                val snapshot = second.launchSnapshot()
                assertEquals(ResumeSection.FEEDS, snapshot?.section)
                assertEquals("INBOX", snapshot?.folder)
                assertEquals(316L, snapshot?.uid)
                assertEquals("sub:s1", snapshot?.feedScope)

                // The user moves on in the second process; the snapshot does not.
                second.recordFolder("Archive")
                advanceUntilIdle()
                assertEquals("Archive", second.current().folder)
                assertEquals("INBOX", second.launchSnapshot()?.folder)
                assertEquals(ResumeSection.FEEDS, second.launchSnapshot()?.section)
            } finally {
                second.close()
            }
        }

    @Test
    fun `sign-out forgets everything`() =
        storeTest { store, file ->
            store.recordMessage("INBOX", 1, null)
            advanceUntilIdle()
            assertTrue(file.exists())
            store.clear()
            advanceUntilIdle()
            assertFalse(file.exists())
            assertEquals(ResumeSession(), store.current())
            assertNull(store.launchSnapshot())
        }

    @Test
    fun `a corrupt file reads as nothing saved`() =
        runTest {
            val file = File(dir, "resume-session.json")
            file.writeText("{not json")
            val store = open(file)
            try {
                assertNull(store.launchSnapshot())
                assertEquals(ResumeSession(), store.current())
            } finally {
                store.close()
            }
        }
}
