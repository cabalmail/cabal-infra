package com.cabalmail.kit.flagged

import com.cabalmail.kit.models.Envelope
import com.cabalmail.kit.models.ItemRef
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.ref
import com.cabalmail.kit.models.sentInstant
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

/** One row of the Flagged view: a message or a feed item, under one identity. */
sealed interface FlaggedRow {
    val ref: ItemRef

    /** The date the row shows and is ordered by; null when the item has none this build can read. */
    val date: Instant?

    data class Mail(
        val envelope: Envelope,
        override val ref: ItemRef.Mail,
    ) : FlaggedRow {
        override val date: Instant? get() = envelope.sentInstant()
    }

    data class Feed(
        val item: RssItem,
    ) : FlaggedRow {
        override val ref: ItemRef.Feed get() = item.ref
        override val date: Instant? get() = item.publishedInstant()
    }
}

/** The two halves of the Flagged view, for saying which one the list is waiting on. */
enum class FlaggedSource { MAIL, FEED }

/**
 * What the Flagged view shows from the rows loaded so far.
 *
 * [cutoff] is the horizon: null once both halves are whole, otherwise the
 * instant the list is complete down to. [heldBack] counts loaded rows
 * older than it, which wait for the page [next] names.
 */
data class FlaggedPage(
    val rows: List<FlaggedRow>,
    val cutoff: Instant?,
    val next: FlaggedSource?,
    val heldBack: Int,
)

/**
 * The Flagged view's one list (`docs/1.x/cross-media-ux-plan.md`, Phase
 * 5): flagged messages and flagged feed items together, newest first,
 * each ordered by the date its row shows.
 *
 * The two halves arrive differently. Feed items are on the device.
 * Messages come from the server's cross-folder search a page at a time,
 * ordered by the day they arrived and, inside a day, by folder and UID,
 * not by time. Interleaving a whole half with a partial one would show an
 * old feed item under a gap where unloaded mail belongs, so the list stops
 * at a horizon: while a half has more to load, nothing older than the
 * point that half is complete down to is shown from either, and the rows
 * past it wait for the next page.
 *
 * For mail that point is a day, and an estimate. A page ends partway
 * through an arrival day, so the half is whole only from the following
 * midnight (UTC, where the server takes its days), and the device knows a
 * message's Date header, not when it arrived. A message whose two dates
 * are more than a day apart can therefore land a page late, in its right
 * place. For feed items the point is exact: they are read in order.
 */
object FlaggedList {
    /** Messages a request, the server's most: each request searches every folder again, so few and large is cheap. */
    const val MAIL_PAGE_SIZE = 200

    /** Feed items a read from the device's store. */
    const val FEED_PAGE_SIZE = 200

    /**
     * The instant the mail half is complete down to, given everything
     * loaded so far in the server's order: null when no page is left.
     * With pages left it is the midnight after the last dated row's day;
     * with no dated row loaded, nothing can be vouched for yet.
     */
    fun mailCutoff(
        loaded: List<Envelope>,
        hasMore: Boolean,
    ): Instant? {
        if (!hasMore) return null
        val last = loaded.asReversed().firstNotNullOfOrNull { it.sentInstant() } ?: return Instant.MAX
        return last
            .atOffset(ZoneOffset.UTC)
            .truncatedTo(ChronoUnit.DAYS)
            .plusDays(1)
            .toInstant()
    }

    /**
     * The instant the feed half is complete down to, given everything
     * read so far, newest first: null when the store has no more. With
     * more to read it is just past the last dated row, since an item
     * published in the same instant may be on the next page.
     */
    fun feedCutoff(
        loaded: List<RssItem>,
        hasMore: Boolean,
    ): Instant? {
        if (!hasMore) return null
        val last = loaded.asReversed().firstNotNullOfOrNull { it.publishedInstant() } ?: return Instant.MAX
        return last.plusNanos(1)
    }

    /**
     * One list from both halves, newest first, cut at the later of the
     * two horizons. A row with no date sorts last, and so shows only once
     * both halves are whole. A message that names no folder cannot be
     * opened and is left out.
     */
    fun merge(
        mail: List<Envelope>,
        mailCutoff: Instant?,
        feed: List<RssItem>,
        feedCutoff: Instant?,
    ): FlaggedPage {
        val all: List<FlaggedRow> =
            mail.mapNotNull { envelope -> envelope.ref()?.let { FlaggedRow.Mail(envelope, it) } } +
                feed.map { FlaggedRow.Feed(it) }
        val cutoff = listOfNotNull(mailCutoff, feedCutoff).maxOrNull()
        val next =
            when {
                cutoff == null -> null
                cutoff == mailCutoff -> FlaggedSource.MAIL
                else -> FlaggedSource.FEED
            }
        val shown =
            if (cutoff == null) {
                all
            } else {
                all.filter { row -> row.date?.let { it >= cutoff } ?: false }
            }
        return FlaggedPage(
            rows = shown.sortedWith(ORDER),
            cutoff = cutoff,
            next = next,
            heldBack = all.size - shown.size,
        )
    }

    /** Newest first, the dateless last, and one fixed order among rows of one instant. */
    private val ORDER: Comparator<FlaggedRow> =
        compareBy<FlaggedRow> { it.date == null }
            .thenByDescending { it.date ?: Instant.MIN }
            .thenBy { it.ref.key }
}

/**
 * A feed item's published date as an instant: the server's ISO timestamp
 * (`2026-09-09T20:25:06+00:00`, with or without a fraction), or null for
 * anything else.
 */
fun RssItem.publishedInstant(): Instant? =
    runCatching { OffsetDateTime.parse(publishedAt).toInstant() }.getOrNull()
        ?: runCatching { Instant.parse(publishedAt) }.getOrNull()
