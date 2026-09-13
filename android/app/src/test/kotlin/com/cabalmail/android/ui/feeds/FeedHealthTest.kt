package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class FeedHealthTest {
    private fun feed(
        failures: Int,
        deadLettered: Boolean = false,
        lastError: String = "",
    ) = RssFeedSummary("f1", consecutiveFailureCount = failures, deadLettered = deadLettered, lastError = lastError)

    @Test
    fun `thresholds match the Apple badge`() {
        assertEquals(FeedHealthLevel.Healthy, FeedHealth.level(null))
        assertEquals(FeedHealthLevel.Healthy, FeedHealth.level(feed(0)))
        assertEquals(FeedHealthLevel.Healthy, FeedHealth.level(feed(2)))
        assertEquals(FeedHealthLevel.Failing(3), FeedHealth.level(feed(3)))
        assertEquals(FeedHealthLevel.Failing(19), FeedHealth.level(feed(19)))
        assertEquals(FeedHealthLevel.Stopped, FeedHealth.level(feed(20)))
        assertEquals(FeedHealthLevel.Stopped, FeedHealth.level(feed(1, deadLettered = true)))
    }

    @Test
    fun `the headline appends the fetcher's words only when the feed is unhealthy`() {
        assertNull(FeedHealth.headline(feed(1, lastError = "HTTP 503"), summary = null))
        assertEquals(
            "Failing: 3 fetches in a row. HTTP 503",
            FeedHealth.headline(feed(3, lastError = " HTTP 503 "), "Failing: 3 fetches in a row"),
        )
        assertEquals("Stopped", FeedHealth.headline(feed(25), "Stopped"))
    }
}
