package com.cabalmail.kit.cache

import com.cabalmail.kit.api.ApiClient
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Session-scoped BIMI logo-URL lookups, negative results included — most
 * senders have no BIMI record and re-asking per row would swamp the API.
 * Lookup failures are cached as absent for the session too: a sender logo
 * is decoration, not worth retry traffic.
 */
class BimiRepository(
    private val api: ApiClient,
) {
    private val mutex = Mutex()
    private val byDomain = mutableMapOf<String, String?>()

    /** Logo URL for [senderDomain], or null when there is none. */
    suspend fun logoUrl(senderDomain: String): String? {
        mutex.withLock {
            if (byDomain.containsKey(senderDomain)) {
                return byDomain[senderDomain]
            }
        }
        val url = runCatching { api.fetchBimi(senderDomain) }.getOrNull()
        mutex.withLock { byDomain[senderDomain] = url }
        return url
    }
}
