package com.cabalmail.kit.auth

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.Base64

/**
 * Admin recognition reads the ID token's `cognito:groups` claim the way the
 * server's `admin_limits.is_admin` does: the `admin` group as a whole element,
 * in the JSON-array form Cognito issues and in the string forms API Gateway
 * renders (auth parity plan, C1; `docs/auth.md`). Mirrors the Apple kit's
 * `IdTokenClaimsTests`.
 */
class IdTokenClaimsTest {
    private fun claims(json: String) = IdTokenClaims(testIdToken(json))

    @Test
    fun `the admin group alone or among others`() {
        assertTrue(claims("""{"cognito:groups":["admin"]}""").isAdmin)
        assertTrue(claims("""{"cognito:groups":["users","admin"]}""").isAdmin)
        assertEquals(listOf("users", "admin"), claims("""{"cognito:groups":["users","admin"]}""").groups)
    }

    @Test
    fun `no groups claim is not admin`() {
        val claims = claims("""{"cognito:username":"alice"}""")
        assertFalse(claims.isAdmin)
        assertEquals(emptyList<String>(), claims.groups)
    }

    /** The trap a substring test falls into: these are other groups. */
    @Test
    fun `a group whose name only contains admin is not the admin group`() {
        assertFalse(claims("""{"cognito:groups":["nonadmin","admin-readonly"]}""").isAdmin)
        assertFalse(claims("""{"cognito:groups":"admin-readonly"}""").isAdmin)
        assertFalse(claims("""{"cognito:groups":"[nonadmin users]"}""").isAdmin)
    }

    @Test
    fun `the string renderings admin_limits accepts`() {
        for (rendering in listOf("admin", "admin,users", "users,admin", "[admin users]", "[users admin]", " admin ")) {
            assertTrue(claims("""{"cognito:groups":"$rendering"}""").isAdmin, "$rendering names the admin group")
        }
        assertEquals(listOf("admin", "users"), claims("""{"cognito:groups":"[admin users]"}""").groups)
    }

    /**
     * base64url maps 62 and 63 to `-` and `_`, which the plain base64 decoder
     * rejects. Three `~` and three `?` in a row guarantee one of each lands on
     * the byte position that encodes alone; an email address can hold either.
     */
    @Test
    fun `a base64url payload with dash and underscore decodes`() {
        val jwt = testIdToken("""{"email":"a~~~b???@example.com","cognito:groups":["admin"]}""")
        val segment = jwt.split('.')[1]
        assertTrue('-' in segment, "precondition: the segment carries '-'")
        assertTrue('_' in segment, "precondition: the segment carries '_'")
        assertThrows(IllegalArgumentException::class.java, { Base64.getDecoder().decode(segment) }, "negative control")
        assertTrue(IdTokenClaims(jwt).isAdmin)
    }

    @Test
    fun `UTF-8 claims decode`() {
        assertTrue(claims("""{"name":"Zoë Ångström","cognito:groups":["admin"]}""").isAdmin)
    }

    @Test
    fun `malformed tokens are not admin`() {
        val arrayPayload = Base64.getUrlEncoder().withoutPadding().encodeToString("""["admin"]""".toByteArray())
        for (malformed in listOf("", "no-dots", "a.!!!.c", "a..c", "a.$arrayPayload.c")) {
            assertFalse(IdTokenClaims(malformed).isAdmin, malformed)
        }
    }

    @Test
    fun `non-string group entries are skipped`() {
        assertEquals(listOf("admin"), claims("""{"cognito:groups":[5,"admin",null]}""").groups)
    }

    @Test
    fun `AuthTokens reads its id token`() {
        val admin =
            AuthTokens(testIdToken("""{"cognito:groups":["admin"]}"""), "access", "refresh", expiresAtEpochMillis = 0)
        assertTrue(admin.isAdmin)
        assertFalse(AuthTokens(testIdToken("{}"), "access", expiresAtEpochMillis = 0).isAdmin)
    }
}
