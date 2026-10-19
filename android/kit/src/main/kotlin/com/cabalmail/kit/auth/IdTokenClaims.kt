package com.cabalmail.kit.auth

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.Base64

/**
 * The claims the Android client reads from a Cognito ID token — the
 * counterpart of the Apple kit's `IdTokenClaims`.
 *
 * No signature check: the token came straight from Cognito over TLS, and what
 * the client reads from it is a display hint. Authorization stays on the
 * server, which checks admin membership itself
 * (`lambda/api/_shared/admin_limits.py`); see `docs/auth.md`, "Admin
 * recognition".
 */
class IdTokenClaims(
    idToken: String,
) {
    /**
     * The `cognito:groups` claim as a list of group names; empty when the
     * claim is absent or the token is malformed.
     */
    val groups: List<String> = payload(idToken)?.let(::groupsIn).orEmpty()

    /**
     * Whether the token names the `admin` group, matched as a whole name the
     * way the server does: a group whose name merely contains "admin"
     * (`nonadmin`, `admin-readonly`) is not the admin group.
     */
    val isAdmin: Boolean get() = ADMIN_GROUP in groups

    private companion object {
        const val ADMIN_GROUP = "admin"
        val SEPARATORS = Regex("\\s+")

        /**
         * The payload segment of a compact JWT, decoded. The URL-safe
         * decoder takes base64url's `-` and `_` and the missing padding.
         */
        fun payload(token: String): JsonObject? {
            val segment = token.split('.').getOrNull(1) ?: return null
            return runCatching {
                Json.parseToJsonElement(Base64.getUrlDecoder().decode(segment).decodeToString()) as? JsonObject
            }.getOrNull()
        }

        /**
         * Cognito puts a JSON array in the token. API Gateway renders the
         * same claim as a string (`admin`, `admin,users`, `[admin users]`),
         * so that is accepted too, split on commas and whitespace once the
         * brackets are trimmed, as `admin_limits.is_admin` splits it.
         */
        fun groupsIn(payload: JsonObject): List<String> =
            when (val claim = payload["cognito:groups"]) {
                is JsonArray -> claim.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content }
                is JsonPrimitive ->
                    if (claim.isString) {
                        claim.content
                            .trim('[', ']')
                            .replace(',', ' ')
                            .split(SEPARATORS)
                            .filter(String::isNotEmpty)
                    } else {
                        emptyList()
                    }
                else -> emptyList()
            }
    }
}

/** Whether this session's ID token names the `admin` group. A hint for what to show, never for what to allow. */
val AuthTokens.isAdmin: Boolean get() = IdTokenClaims(idToken).isAdmin

/**
 * Whether the signed-in user is an administrator, read from the tokens stored
 * right now: false when signed out. Nothing is cached, so the answer follows a
 * refresh (a group granted or removed takes effect with the next token
 * Cognito issues), a sign-out, and an account switch. A display hint; a 403
 * from the server is the authority.
 */
fun AuthService.isAdmin(): Boolean = currentTokens()?.isAdmin ?: false
