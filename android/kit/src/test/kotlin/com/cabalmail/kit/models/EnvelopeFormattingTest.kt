package com.cabalmail.kit.models

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant

class EnvelopeFormattingTest {
    @Test
    fun `wire dates parse and the None sentinel maps to null`() {
        assertEquals(
            Instant.parse("2024-01-15T10:30:45Z"),
            Envelope(id = 1, date = "2024-01-15 10:30:45+00:00").sentInstant(),
        )
        assertEquals(
            Instant.parse("2024-01-15T15:30:45Z"),
            Envelope(id = 1, date = "2024-01-15 10:30:45-05:00").sentInstant(),
        )
        // Naive (offset-less) wire dates — the common live shape — read as UTC.
        assertEquals(
            Instant.parse("2026-07-26T10:21:06Z"),
            Envelope(id = 1, date = "2026-07-26 10:21:06").sentInstant(),
        )
        // str(datetime) includes microseconds when present.
        assertEquals(
            Instant.parse("2024-01-15T10:30:45.123456Z"),
            Envelope(id = 1, date = "2024-01-15 10:30:45.123456+00:00").sentInstant(),
        )
        assertNull(Envelope(id = 1, date = "None").sentInstant())
        assertNull(Envelope(id = 1).sentInstant())
    }

    @Test
    fun `mailbox display names strip quotes and fall back sensibly`() {
        assertEquals("Ann Example", mailboxDisplayName("\"Ann Example\" <a@b.c>"))
        assertEquals("Ann", mailboxDisplayName("Ann <a@b.c>"))
        assertEquals("a@b.c", mailboxDisplayName("a@b.c"))
        assertEquals("a@b.c", mailboxDisplayName("<a@b.c>"))
        assertEquals("undisclosed-recipients", mailboxDisplayName("undisclosed-recipients"))
    }

    @Test
    fun `mailbox addresses extract from angle brackets or bare form`() {
        assertEquals("a@b.c", mailboxAddress("\"Ann\" <a@b.c>"))
        assertEquals("a@b.c", mailboxAddress("a@b.c"))
        assertNull(mailboxAddress("undisclosed-recipients"))
    }

    @Test
    fun `delivered-to prefers an owned-domain recipient, subdomain-aware`() {
        val domains = listOf("cabalmail.com")
        // The owned address wins even when listed after an outside one.
        assertEquals(
            "xkcd@store.cabalmail.com",
            Envelope(
                id = 1,
                to = listOf("Other <other@example.com>", "\"Me\" <xkcd@store.cabalmail.com>"),
            ).deliveredToAddress(domains),
        )
        // Cc is searched when To has no owned address.
        assertEquals(
            "me@shop.cabalmail.com",
            Envelope(
                id = 1,
                to = listOf("other@example.com"),
                cc = listOf("me@shop.cabalmail.com"),
            ).deliveredToAddress(domains),
        )
        // Subdomain matching is anchored: a lookalike domain is not owned.
        assertEquals(
            "me@a.cabalmail.com",
            Envelope(
                id = 1,
                to = listOf("x@evilcabalmail.com", "me@a.cabalmail.com"),
            ).deliveredToAddress(domains),
        )
        // No owned match falls back to the first recipient.
        assertEquals(
            "other@example.com",
            Envelope(id = 1, to = listOf("Other <other@example.com>")).deliveredToAddress(domains),
        )
        // No recipients (e.g. a draft) yields null, dropping the arrow.
        assertNull(Envelope(id = 1).deliveredToAddress(domains))
        assertNull(Envelope(id = 1, to = listOf("undisclosed-recipients")).deliveredToAddress(domains))
    }

    @Test
    fun `auth failure warns only on explicit failure verdicts`() {
        assertTrue(
            Envelope(id = 1, authResults = AuthResults(spf = "pass", dmarc = "fail")).hasAuthFailure,
        )
        assertFalse(
            Envelope(id = 1, authResults = AuthResults(spf = "pass", dkim = "pass")).hasAuthFailure,
        )
        // Absence of results is "not verified", not a warning.
        assertFalse(Envelope(id = 1).hasAuthFailure)
        assertFalse(Envelope(id = 1, authResults = AuthResults(spf = "none")).hasAuthFailure)
    }
}
