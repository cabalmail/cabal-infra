package com.cabalmail.android

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MailEventBusTest {
    @Test
    fun `flag write shield tracks the written uids in their folder`() {
        val bus = MailEventBus()
        bus.beginFlagWrite("INBOX", listOf(1L, 2L))
        assertTrue(bus.flagWriteInFlight("INBOX", 1L))
        assertTrue(bus.flagWriteInFlight("INBOX", 2L))
        assertFalse(bus.flagWriteInFlight("INBOX", 3L))
        assertFalse(bus.flagWriteInFlight("Archive", 1L))
        assertTrue(bus.writesInFlight)
        bus.endFlagWrite("INBOX", listOf(1L, 2L))
        assertFalse(bus.flagWriteInFlight("INBOX", 1L))
        assertFalse(bus.writesInFlight)
    }

    @Test
    fun `shield clears only when every overlapping write settles`() {
        val bus = MailEventBus()
        bus.beginFlagWrite("INBOX", listOf(1L))
        bus.beginFlagWrite("INBOX", listOf(1L))
        bus.endFlagWrite("INBOX", listOf(1L))
        assertTrue(bus.flagWriteInFlight("INBOX", 1L))
        bus.endFlagWrite("INBOX", listOf(1L))
        assertFalse(bus.flagWriteInFlight("INBOX", 1L))
    }

    /**
     * #1734: a screen answering an optimistic event by READING server state
     * — the Folders screen refetching a folder's message count — has to let
     * the write land, or it reads the pre-move count back and keeps it.
     */
    @Test
    fun `waiting for writes to settle holds until the write ends`() =
        runTest {
            val bus = MailEventBus()
            bus.beginWrite()
            var settled = false
            launch {
                bus.awaitWritesSettled()
                settled = true
            }
            runCurrent()
            assertFalse(settled, "the count STATUS went out while the move was still in flight")
            bus.endWrite()
            advanceUntilIdle()
            assertTrue(settled)
        }

    @Test
    fun `waiting for writes to settle returns at once when none is in flight`() =
        runTest {
            val bus = MailEventBus()
            bus.beginWrite()
            bus.endWrite()
            bus.awaitWritesSettled()
        }
}
