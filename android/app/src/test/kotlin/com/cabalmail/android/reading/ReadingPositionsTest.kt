package com.cabalmail.android.reading

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** The per-item reading-position cache (mail and feeds) and its `f<fraction>` anchor codec. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReadingPositionsTest {
    @TempDir
    lateinit var dir: File

    @Test
    fun `anchors round-trip in the Apple fallback form and the top is not stored`() {
        assertEquals("f0.420", ReadingAnchor.format(0.42f))
        assertEquals("f1.000", ReadingAnchor.format(3f))
        assertNull(ReadingAnchor.format(0.004f))
        assertEquals(0.42f, ReadingAnchor.fraction("f0.420"))
        assertNull(ReadingAnchor.fraction("i3/1|12"))
        assertNull(ReadingAnchor.fraction("f2"))
    }

    @Test
    fun `keys follow the Apple scheme so mail and feeds never collide`() {
        assertEquals("mail:<id@x>", ReadingPositionKey.mail("<id@x>", "INBOX", 7))
        assertEquals("mail:INBOX#7", ReadingPositionKey.mail(null, "INBOX", 7))
        assertEquals("mail:INBOX#7", ReadingPositionKey.mail("", "INBOX", 7))
        assertEquals("feed:f1#k1", ReadingPositionKey.feed("f1#k1"))
    }

    @Test
    fun `positions persist, evict the oldest beyond capacity, and clear at the top`() =
        runTest {
            val dispatcher = StandardTestDispatcher(testScheduler)
            val file = File(dir, "positions.json")
            val positions = ReadingPositions(file, capacity = 2, io = dispatcher)

            positions.record("feed:f1#a", 0.25f)
            positions.record("mail:<m@x>", 0.5f)
            positions.record("feed:f1#c", 0.75f)
            assertNull(positions.fraction("feed:f1#a"), "oldest evicted")
            assertEquals(0.5f, positions.fraction("mail:<m@x>"))

            positions.record("mail:<m@x>", 0f)
            assertNull(positions.fraction("mail:<m@x>"), "a position at the top clears the entry")

            val reopened = ReadingPositions(file, io = dispatcher)
            assertEquals(0.75f, reopened.fraction("feed:f1#c"))
            assertEquals("f0.750", reopened.anchor("feed:f1#c"))
        }

    @Test
    fun `the feed-only file from before the mail half is adopted once`() =
        runTest {
            val dispatcher = StandardTestDispatcher(testScheduler)
            val legacy = File(dir, "feed-positions.json")
            legacy.writeText("""{"f1#a":"f0.111","f1#b":"f0.500"}""")
            val file = File(dir, "reading-positions.json")
            val positions = ReadingPositions(file, legacyFeedFile = legacy, io = dispatcher)

            assertEquals(0.111f, positions.fraction("feed:f1#a"))
            assertEquals(0.5f, positions.fraction("feed:f1#b"))
            // The first write moves the entries into the new file.
            positions.record("mail:<m@x>", 0.3f)
            assertFalse(legacy.exists())
            val reopened = ReadingPositions(file, legacyFeedFile = legacy, io = dispatcher)
            assertEquals(0.111f, reopened.fraction("feed:f1#a"))
            assertEquals(0.3f, reopened.fraction("mail:<m@x>"))
        }

    @Test
    fun `sign-out forgets every position`() =
        runTest {
            val dispatcher = StandardTestDispatcher(testScheduler)
            val file = File(dir, "positions.json")
            val positions = ReadingPositions(file, io = dispatcher)
            positions.record("feed:f1#a", 0.25f)
            positions.clear()
            assertFalse(file.exists())
            assertNull(positions.fraction("feed:f1#a"))
        }
}
