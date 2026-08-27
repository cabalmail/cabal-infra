package com.cabalmail.kit.auth

import com.cabalmail.kit.CabalmailException
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CognitoAuthServiceTest {
    private class InMemoryTokenStore : TokenStore {
        var tokens: AuthTokens? = null
        var username: String? = null

        override fun readTokens(): AuthTokens? = tokens

        override fun writeTokens(tokens: AuthTokens) {
            this.tokens = tokens
        }

        override fun readUsername(): String? = username

        override fun writeUsername(username: String) {
            this.username = username
        }

        override fun clear() {
            tokens = null
            username = null
        }
    }

    /** Records each request's X-Amz-Target and body; replies from a queue. */
    private class CognitoStub(
        vararg responses: Pair<HttpStatusCode, String>,
    ) {
        val targets = mutableListOf<String>()
        val bodies = mutableListOf<String>()
        private val queue = responses.toMutableList()

        val client =
            HttpClient(
                MockEngine { request ->
                    targets += request.headers["X-Amz-Target"].orEmpty()
                    bodies += (request.body as TextContent).text
                    val (code, body) = queue.removeAt(0)
                    respond(
                        content = body,
                        status = code,
                        headers = headersOf(HttpHeaders.ContentType, "application/x-amz-json-1.1"),
                    )
                },
            )
    }

    private fun authResult(
        id: String = "id-token",
        refresh: String? = "refresh-token",
        expiresIn: Int = 3600,
    ): String {
        val refreshLine = if (refresh != null) """"RefreshToken": "$refresh",""" else ""
        return """
            {
              "AuthenticationResult": {
                "IdToken": "$id",
                "AccessToken": "access-token",
                $refreshLine
                "ExpiresIn": $expiresIn,
                "TokenType": "Bearer"
              }
            }
            """.trimIndent()
    }

    private fun service(
        stub: CognitoStub,
        store: InMemoryTokenStore = InMemoryTokenStore(),
        clock: () -> Long = { 1_000_000L },
    ) = CognitoAuthService("client-id", "us-east-1", stub.client, store, clock)

    @Test
    fun `sign-in without mfa stores tokens and username`() =
        runTest {
            val stub = CognitoStub(HttpStatusCode.OK to authResult())
            val store = InMemoryTokenStore()

            val result = service(stub, store).signIn("chris", "hunter2")

            assertEquals(SignInResult.SignedIn, result)
            assertEquals("id-token", store.tokens?.idToken)
            assertEquals("refresh-token", store.tokens?.refreshToken)
            assertEquals("chris", store.username)
            assertEquals("AWSCognitoIdentityProviderService.InitiateAuth", stub.targets.single())
            assertTrue(stub.bodies.single().contains("\"AuthFlow\":\"USER_PASSWORD_AUTH\""))
        }

    @Test
    fun `totp challenge defers tokens until the code is submitted`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.OK to
                        """{"ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": "opaque-session"}""",
                    HttpStatusCode.OK to authResult(),
                )
            val store = InMemoryTokenStore()
            val auth = service(stub, store)

            val result = auth.signIn("chris", "hunter2")

            assertEquals(SignInResult.MfaCodeRequired(MfaMethod.TOTP), result)
            assertNull(store.tokens)

            auth.submitMfaCode("123456")

            assertEquals("id-token", store.tokens?.idToken)
            assertEquals("chris", store.username)
            val challengeBody = stub.bodies[1]
            assertTrue(challengeBody.contains("\"Session\":\"opaque-session\""))
            assertTrue(challengeBody.contains("\"SOFTWARE_TOKEN_MFA_CODE\":\"123456\""))
        }

    @Test
    fun `submitMfaCode without a pending challenge throws NotSignedIn`() =
        runTest {
            val auth = service(CognitoStub())

            val exception = runCatching { auth.submitMfaCode("123456") }.exceptionOrNull()

            assertTrue(exception is CabalmailException.NotSignedIn)
        }

    @Test
    fun `currentIdToken returns stored token while fresh`() =
        runTest {
            val store = InMemoryTokenStore()
            store.tokens =
                AuthTokens(
                    idToken = "fresh",
                    accessToken = "a",
                    refreshToken = "r",
                    expiresAtEpochMillis = 1_000_000L + 3_600_000L,
                )
            val stub = CognitoStub()

            assertEquals("fresh", service(stub, store).currentIdToken())
            assertTrue(stub.targets.isEmpty())
        }

    @Test
    fun `currentIdToken refreshes an expired token and keeps the refresh token`() =
        runTest {
            val store = InMemoryTokenStore()
            store.tokens =
                AuthTokens(
                    idToken = "stale",
                    accessToken = "a",
                    refreshToken = "keep-me",
                    // Within the 5-minute leeway of the fixed clock.
                    expiresAtEpochMillis = 1_000_000L + 60_000L,
                )
            // REFRESH_TOKEN_AUTH responses omit RefreshToken.
            val stub = CognitoStub(HttpStatusCode.OK to authResult(id = "renewed", refresh = null))

            val token = service(stub, store).currentIdToken()

            assertEquals("renewed", token)
            assertEquals("keep-me", store.tokens?.refreshToken)
            assertTrue(stub.bodies.single().contains("\"AuthFlow\":\"REFRESH_TOKEN_AUTH\""))
        }

    @Test
    fun `currentIdToken with no session throws NotSignedIn`() =
        runTest {
            val exception =
                runCatching { service(CognitoStub()).currentIdToken() }.exceptionOrNull()

            assertTrue(exception is CabalmailException.NotSignedIn)
        }

    @Test
    fun `NotAuthorizedException maps to InvalidCredentials`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.BadRequest to
                        """{"__type": "x#NotAuthorizedException", "message": "Incorrect username or password."}""",
                )

            val exception =
                runCatching { service(stub).signIn("chris", "wrong") }.exceptionOrNull()

            assertTrue(exception is CabalmailException.InvalidCredentials)
        }

    // #1288: Cognito answers NotAuthorizedException to a refresh whose token
    // has expired or been revoked, exactly as it does to a sign-in with a bad
    // password. Only the refresh path knows nobody typed anything, so it is
    // the one that has to say "session expired".
    @Test
    fun `a refused refresh maps to AuthExpired, not InvalidCredentials`() =
        runTest {
            val store = InMemoryTokenStore()
            store.tokens =
                AuthTokens(
                    idToken = "stale",
                    accessToken = "a",
                    refreshToken = "aged-out",
                    // Within the 5-minute leeway of the fixed clock.
                    expiresAtEpochMillis = 1_000_000L + 60_000L,
                )
            val stub =
                CognitoStub(
                    HttpStatusCode.BadRequest to
                        """{"__type": "x#NotAuthorizedException", "message": "Refresh Token has been revoked"}""",
                )

            val exception =
                runCatching { service(stub, store).currentIdToken() }.exceptionOrNull()

            assertTrue(exception is CabalmailException.AuthExpired)
            // The refusal has to have come from the refresh, not a sign-in.
            assertTrue(stub.bodies.single().contains("\"AuthFlow\":\"REFRESH_TOKEN_AUTH\""))
        }

    @Test
    fun `lambda trigger rejections surface the trigger's own message`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.BadRequest to
                        """
                        {"__type": "UserLambdaValidationException",
                         "message": "PreSignUp failed with error An invitation is required.."}
                        """.trimIndent(),
                )

            val exception =
                runCatching { service(stub).signUp("chris", "pw", "a@b.example", null) }
                    .exceptionOrNull() as CabalmailException.ServerError

            assertEquals("An invitation is required.", exception.message)
        }

    @Test
    fun `signOut clears the store and pending challenge`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.OK to
                        """{"ChallengeName": "SOFTWARE_TOKEN_MFA", "Session": "s"}""",
                )
            val store = InMemoryTokenStore()
            store.username = "chris"
            val auth = service(stub, store)
            auth.signIn("chris", "hunter2")

            auth.signOut()

            assertNull(store.username)
            val exception = runCatching { auth.submitMfaCode("123456") }.exceptionOrNull()
            assertTrue(exception is CabalmailException.NotSignedIn)
        }

    @Test
    fun `trigger wrapper stripping is conservative`() {
        assertEquals(
            "An invitation is required.",
            CognitoAuthService.stripLambdaTriggerWrapper(
                "PreSignUp failed with error An invitation is required..",
            ),
        )
        // Mid-sentence occurrences are left alone.
        assertEquals(
            "The thing failed with error code 7.",
            CognitoAuthService.stripLambdaTriggerWrapper("The thing failed with error code 7."),
        )
    }
}
