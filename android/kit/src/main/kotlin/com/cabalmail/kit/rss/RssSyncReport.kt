package com.cabalmail.kit.rss

/**
 * What one [RssSyncEngine.syncAll] pass managed, with the three kinds of
 * failure kept apart. They used to share one map keyed by subscription id,
 * so a failed queue push or catalog refresh counted as a feed and the feed
 * list's "every feed failed" line appeared — or stayed away — for the
 * wrong reasons (#1954). Mirrors the Apple kit's `RssSyncReport`.
 */
data class RssSyncReport(
    /** The catalog could not be fetched, which ends the pass. */
    val catalogFailure: Throwable? = null,
    /** The subscriptions the pass tried, in store order. */
    val subscriptionIds: List<String> = emptyList(),
    /** The feeds that failed, by subscription id. */
    val feedFailures: Map<String, Throwable> = emptyMap(),
    /** The pending queue's drain failed; the queue stays for the next pass. */
    val pendingFailure: Throwable? = null,
) {
    /** Nothing at all went wrong. */
    val isClean: Boolean
        get() = catalogFailure == null && feedFailures.isEmpty() && pendingFailure == null

    /**
     * The pass tried at least one feed and every one failed, which almost
     * always means the device is offline.
     */
    val everyFeedFailed: Boolean
        get() = subscriptionIds.isNotEmpty() && subscriptionIds.all { feedFailures.containsKey(it) }

    /**
     * The first failed feed in store order, so the one line a view shows
     * does not depend on map order.
     */
    val firstFeedFailure: Throwable?
        get() = subscriptionIds.firstNotNullOfOrNull { feedFailures[it] }
}
