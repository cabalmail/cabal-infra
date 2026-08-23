package com.cabalmail.android.notifications

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class NotificationActionTest {
    @Test
    fun `round-trips a valid action`() {
        val action = NotificationAction.fromValues("ARCHIVE", "INBOX", 4271, 4271)

        assertEquals(
            NotificationAction(NotificationAction.Verb.ARCHIVE, "INBOX", 4271, 4271),
            action,
        )
    }

    @Test
    fun `unknown verb, blank folder, or unresolved uid are unactionable`() {
        assertNull(NotificationAction.fromValues("EXPLODE", "INBOX", 1, 1))
        assertNull(NotificationAction.fromValues(null, "INBOX", 1, 1))
        assertNull(NotificationAction.fromValues("MARK_READ", " ", 1, 1))
        assertNull(NotificationAction.fromValues("MARK_READ", null, 1, 1))
        assertNull(NotificationAction.fromValues("MARK_READ", "INBOX", 0, 1))
    }

    @Test
    fun `no actions without a resolved uid`() {
        assertEquals(emptyList<NotificationAction.Verb>(), NotificationAction.eligible("INBOX", 0, "Archive"))
    }

    @Test
    fun `both actions on ordinary folders`() {
        assertEquals(
            listOf(NotificationAction.Verb.MARK_READ, NotificationAction.Verb.ARCHIVE),
            NotificationAction.eligible("INBOX", 7, "Archive"),
        )
    }

    @Test
    fun `no archive action inside the archive folder, case-insensitively`() {
        assertEquals(
            listOf(NotificationAction.Verb.MARK_READ),
            NotificationAction.eligible("archive", 7, "Archive"),
        )
    }
}
