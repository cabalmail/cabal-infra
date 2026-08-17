package com.cabalmail.kit.cache

import com.cabalmail.kit.models.Envelope

/**
 * Envelope cache backing the sliding-window message list: a revisited folder
 * paints from here before the network refresh lands. LRU-bounded, not a
 * full-folder mirror — Cabalmail mailboxes can be very large, so only the
 * working window plus recent bands are kept.
 *
 * Implementations: [RoomEnvelopeCache] (production, survives process death)
 * and [InMemoryEnvelopeCache] (tests, non-persistent fallback).
 */
interface EnvelopeCache {
    /**
     * Validates the folder's cache against the server's UIDVALIDITY (from
     * `/folder_status`), clearing the folder on mismatch — after a mismatch
     * every cached UID in it is meaningless. Call before reads.
     */
    suspend fun reconcile(
        folder: String,
        uidValidity: Long,
    )

    /** Cached envelopes among [uids], keyed by UID. Touches LRU recency. */
    suspend fun read(
        folder: String,
        uids: List<Long>,
    ): Map<Long, Envelope>

    suspend fun write(
        folder: String,
        envelopes: Collection<Envelope>,
    )

    /** Drops one folder's entries (e.g. after a destructive bulk move). */
    suspend fun invalidateFolder(folder: String)

    suspend fun clear()
}
