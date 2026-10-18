package com.cabalmail.kit.auth

import java.util.Base64

/**
 * An unsigned compact JWT whose payload is [claimsJson]. The kit reads ID-token
 * claims without verifying a signature ([IdTokenClaims]), so a test token
 * needs nothing more than a decodable payload.
 */
internal fun testIdToken(claimsJson: String): String {
    val encoder = Base64.getUrlEncoder().withoutPadding()
    val header = encoder.encodeToString("""{"alg":"RS256","kid":"test"}""".toByteArray())
    val payload = encoder.encodeToString(claimsJson.toByteArray())
    return "$header.$payload.c2lnbmF0dXJl"
}
