package com.cabalmail.android.ui.feeds

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

/**
 * The server's ISO timestamps (`2026-09-09T20:25:06+00:00`, with or
 * without fractional seconds) as the list's relative form and the reader's
 * absolute form; unparseable input reads as empty, as on Apple.
 */
object FeedItemDate {
    fun parse(value: String): Instant? =
        runCatching { OffsetDateTime.parse(value).toInstant() }.getOrNull()
            ?: runCatching { Instant.parse(value) }.getOrNull()

    /** `now`, `5m`, `3h`, `2d`, else the short date — coarse, like the Apple rows' short style. */
    fun relative(
        value: String,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val instant = parse(value) ?: return ""
        val minutes = ChronoUnit.MINUTES.between(instant, now)
        return when {
            minutes < 1 -> "now"
            minutes < 60 -> "${minutes}m"
            minutes < 60 * 24 -> "${minutes / 60}h"
            minutes < 60 * 24 * 7 -> "${minutes / (60 * 24)}d"
            else -> DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(zone).format(instant)
        }
    }

    fun absolute(
        value: String,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val instant = parse(value) ?: return ""
        return DateTimeFormatter
            .ofLocalizedDateTime(
                FormatStyle.MEDIUM,
                FormatStyle.SHORT,
            ).withZone(zone)
            .format(instant)
    }
}
