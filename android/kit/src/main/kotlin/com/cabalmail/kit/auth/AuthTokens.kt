package com.cabalmail.kit.auth

import kotlinx.serialization.Serializable

/**
 * The Cognito token triple. Serializable because [TokenStore] persists it as
 * JSON inside encrypted storage.
 */
@Serializable
data class AuthTokens(
    val idToken: String,
    val accessToken: String,
    val refreshToken: String? = null,
    val tokenType: String = "Bearer",
    val expiresAtEpochMillis: Long,
) {
    /**
     * True when the tokens are past (or within [leewayMillis] of) expiry —
     * the five-minute leeway means callers refresh slightly early rather
     * than racing the deadline mid-request.
     */
    fun isExpired(
        nowEpochMillis: Long,
        leewayMillis: Long = DEFAULT_LEEWAY_MILLIS,
    ): Boolean = nowEpochMillis >= expiresAtEpochMillis - leewayMillis

    companion object {
        private const val DEFAULT_LEEWAY_MILLIS = 5 * 60 * 1000L
    }
}
