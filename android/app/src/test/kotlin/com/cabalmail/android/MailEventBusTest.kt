package com.cabalmail.android

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

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
}
