package com.cabalmail.kit.config

/**
 * Persistence seam for the raw `config.json` payload, so [ConfigService] can
 * be unit-tested without Android storage. The production implementation is
 * [DataStoreConfigCache].
 */
interface ConfigCache {
    /** Returns the cached raw JSON, or null if nothing has been cached yet. */
    suspend fun read(): String?

    suspend fun write(raw: String)
}
