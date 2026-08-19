package com.cabalmail.kit.config

/**
 * Persistence seam for the raw `config.json` payload and the control domain
 * it was fetched from, so [ConfigService] can be unit-tested without Android
 * storage. The production implementation is [DataStoreConfigCache].
 *
 * The domain travels with the payload because a cached config is only a
 * valid offline fallback for the server it came from: signing in to a
 * different control domain must never paint from the previous one's cache.
 * The entry also doubles as the remembered "last server" the sign-in form
 * prefills, so it is deliberately not cleared on sign-out.
 */
interface ConfigCache {
    /** Returns the cached entry, or null if nothing has been cached yet. */
    suspend fun read(): CachedConfig?

    suspend fun write(
        controlDomain: String,
        raw: String,
    )
}

/** One cached `config.json`: the normalized control domain and the raw payload. */
data class CachedConfig(
    val controlDomain: String,
    val raw: String,
)
