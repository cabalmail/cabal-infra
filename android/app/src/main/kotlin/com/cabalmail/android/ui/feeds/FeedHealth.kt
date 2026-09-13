package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary

/** What the fetcher's view of a feed means for the sidebar badge (rss plan, phase 10, pulled forward). */
sealed interface FeedHealthLevel {
    data object Healthy : FeedHealthLevel

    data class Failing(
        val consecutiveFailures: Int,
    ) : FeedHealthLevel

    data object Stopped : FeedHealthLevel
}

/**
 * The health thresholds the Apple sidebar uses: a warning mark after three
 * consecutive fetch failures, a stop mark once the fetcher has given up
 * (twenty in a row, or dead-lettered). Pure, so the mapping is unit-tested
 * without Compose; the composables turn a level into words and a glyph.
 */
object FeedHealth {
    const val WARNING_THRESHOLD = 3
    const val STOPPED_THRESHOLD = 20

    fun level(feed: RssFeedSummary?): FeedHealthLevel {
        if (feed == null) return FeedHealthLevel.Healthy
        if (feed.deadLettered || feed.consecutiveFailureCount >= STOPPED_THRESHOLD) return FeedHealthLevel.Stopped
        if (feed.consecutiveFailureCount >= WARNING_THRESHOLD) {
            return FeedHealthLevel.Failing(feed.consecutiveFailureCount)
        }
        return FeedHealthLevel.Healthy
    }

    /**
     * The item list's header line: the level's [summary] followed by the
     * fetcher's own words when it left any. Null for a healthy feed.
     */
    fun headline(
        feed: RssFeedSummary?,
        summary: String?,
    ): String? {
        if (summary == null || feed == null) return null
        val words = feed.lastError.trim()
        return if (words.isEmpty()) summary else "$summary. $words"
    }
}
