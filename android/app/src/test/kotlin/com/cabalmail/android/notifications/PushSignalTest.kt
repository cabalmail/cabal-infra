package com.cabalmail.android.notifications

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PushSignalTest {
    @Test
    fun `parses a complete wake signal`() {
        val signal =
            PushSignal.from(mapOf("folder" to "INBOX", "uid" to "4271", "msg_id" to "<a@x>"))

        assertEquals(PushSignal("INBOX", 4271, "<a@x>"), signal)
    }

    @Test
    fun `zero uid is a hint the dispatcher could not resolve`() {
        val signal = PushSignal.from(mapOf("folder" to "INBOX", "uid" to "0", "msg_id" to "<a@x>"))

        assertEquals(PushSignal("INBOX", null, "<a@x>"), signal)
    }

    @Test
    fun `missing folder is not a signal`() {
        assertNull(PushSignal.from(mapOf("uid" to "1", "msg_id" to "<a@x>")))
        assertNull(PushSignal.from(mapOf("folder" to "  ", "uid" to "1")))
    }

    @Test
    fun `neither uid nor msg_id identifies nothing`() {
        assertNull(PushSignal.from(mapOf("folder" to "INBOX", "uid" to "0", "msg_id" to "")))
        assertNull(PushSignal.from(mapOf("folder" to "INBOX")))
    }

    @Test
    fun `non-numeric uid degrades to the msg_id`() {
        val signal = PushSignal.from(mapOf("folder" to "INBOX", "uid" to "x", "msg_id" to "<a@x>"))

        assertEquals(PushSignal("INBOX", null, "<a@x>"), signal)
    }

    @Test
    fun `notification id prefers the server-resolved uid`() {
        val signal = PushSignal("INBOX", 7, "<a@x>")

        assertEquals(4271, pushNotificationId(signal, resolvedUid = 4271))
    }

    @Test
    fun `notification id falls back to the signal uid then the msg_id hash`() {
        assertEquals(7, pushNotificationId(PushSignal("INBOX", 7, "<a@x>"), resolvedUid = null))
        assertEquals(
            "<a@x>".hashCode(),
            pushNotificationId(PushSignal("INBOX", null, "<a@x>"), resolvedUid = null),
        )
    }

    @Test
    fun `redelivered signal maps to the same notification id`() {
        val first = PushSignal.from(mapOf("folder" to "INBOX", "uid" to "0", "msg_id" to "<a@x>"))!!
        val second = PushSignal.from(mapOf("folder" to "INBOX", "uid" to "0", "msg_id" to "<a@x>"))!!

        assertEquals(
            pushNotificationId(first, resolvedUid = null),
            pushNotificationId(second, resolvedUid = null),
        )
    }
}
