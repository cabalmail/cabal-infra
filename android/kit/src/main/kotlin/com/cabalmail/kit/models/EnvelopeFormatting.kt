package com.cabalmail.kit.models

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatterBuilder
import java.time.temporal.ChronoField

// Display helpers over the wire models. Pure functions so the app layer's
// rows stay dumb and this logic stays unit-tested.

// `str(datetime)` output. Both the fraction and the offset are optional:
// microseconds appear only when present, and the offset only when the
// origin Date header carried one — live stage data is usually naive
// ("2026-07-26 10:21:06").
private val WIRE_DATE =
    DateTimeFormatterBuilder()
        .appendPattern("yyyy-MM-dd HH:mm:ss")
        .optionalStart()
        .appendFraction(ChronoField.NANO_OF_SECOND, 1, 9, true)
        .optionalEnd()
        .optionalStart()
        .appendPattern("XXX")
        .optionalEnd()
        .toFormatter()

/**
 * The envelope's date as an [Instant], or null — the wire carries the
 * literal string `"None"` for dateless messages, and decode-failure
 * sentinels are possible on hostile input. Offset-less values are read as
 * UTC (the least-wrong assumption; row display is day-granular anyway).
 */
fun Envelope.sentInstant(): Instant? =
    runCatching {
        val parsed = WIRE_DATE.parseBest(date, java.time.OffsetDateTime::from, LocalDateTime::from)
        when (parsed) {
            is java.time.OffsetDateTime -> parsed.toInstant()
            is LocalDateTime -> parsed.toInstant(ZoneOffset.UTC)
            else -> null
        }
    }.getOrNull()

/**
 * Human name from an RFC 5322 mailbox string: `"Ann Example" <a@b.c>` and
 * `Ann <a@b.c>` yield `Ann Example` / `Ann`; a bare `a@b.c` yields itself.
 */
fun mailboxDisplayName(mailbox: String): String {
    val angle = mailbox.lastIndexOf('<')
    if (angle < 0) {
        return mailbox.trim()
    }
    val name =
        mailbox
            .substring(0, angle)
            .trim()
            .removeSurrounding("\"")
            .trim()
    return name.ifEmpty { mailboxAddress(mailbox) ?: mailbox.trim() }
}

/** Bare address from an RFC 5322 mailbox string, or null when absent. */
fun mailboxAddress(mailbox: String): String? {
    val start = mailbox.lastIndexOf('<')
    val end = mailbox.lastIndexOf('>')
    if (start >= 0 && end > start) {
        return mailbox.substring(start + 1, end).trim().takeIf { it.isNotEmpty() }
    }
    return mailbox.trim().takeIf { it.contains('@') }
}

/**
 * True when any present SPF/DKIM/DMARC verdict failed outright. Absence of
 * results is "not verified", which is not a warning state.
 */
val Envelope.hasAuthFailure: Boolean
    get() =
        authResults?.let { results ->
            listOfNotNull(results.spf, results.dkim, results.dmarc).any { it == "fail" || it == "permerror" }
        } ?: false
