package com.cabalmail.kit.cache

import com.cabalmail.kit.models.Draft
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class DraftStoreTest {
    @TempDir
    lateinit var dir: File

    @Test
    fun `save load list delete round-trip`() =
        runTest {
            val store = DraftStore(File(dir, "drafts"))
            store.save(Draft(id = "a", updatedAt = 1, subject = "first"))
            store.save(Draft(id = "b", updatedAt = 2, subject = "second", attachments = emptyList()))
            assertEquals(listOf("b", "a"), store.list().map { it.id })
            assertEquals("first", store.load("a")?.subject)

            val file = store.importAttachment("b", "../evil name.txt", "hello".byteInputStream())
            assertTrue(file.isFile)
            assertEquals("evil name.txt", file.name)
            val dup = store.importAttachment("b", "evil name.txt", "again".byteInputStream())
            assertEquals("evil name-1.txt", dup.name)

            store.delete("b")
            assertNull(store.load("b"))
            assertTrue(!store.attachmentDir("b").exists())
            assertEquals(listOf("a"), store.list().map { it.id })
        }

    @Test
    fun `recipient history ranks by count then recency and caps`() =
        runTest {
            var now = 0L
            val history = RecipientHistory(File(dir, "recipients.json"), maxEntries = 3, clock = { now++ })
            history.record(listOf("a@x", "b@x"))
            history.record(listOf("b@x", "c@x"))
            history.record(listOf("d@x"))
            assertEquals(listOf("b@x", "d@x", "c@x"), history.suggest("@x"))
            assertEquals(listOf("d@x"), history.suggest("d"))
            assertTrue(history.suggest("").isEmpty())
            assertEquals(listOf("d@x", "c@x"), history.suggest("@x", exclude = listOf("B@X")))
        }
}
