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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The recovery-email calls (`docs/auth.md`, "After sign-in" and "Recovery
 * email"; auth parity B4): what the check after sign-in asks under plan D5,
 * how `GetUser`'s attributes are read, and what the three writes send.
 */
class RecoveryEmailTest {
    // The check after sign-in (plan D5)

    @Test
    fun `an unverified email is offered for verification whatever the phone says`() {
        val contacts = RecoveryContacts("alice@example.net", emailVerified = false, phoneVerified = true)
        assertEquals(RecoveryEmailPrompt.Verify("alice@example.net"), contacts.promptAfterSignIn(smsEnabled = true))
        assertEquals(RecoveryEmailPrompt.Verify("alice@example.net"), contacts.promptAfterSignIn(smsEnabled = false))
    }

    @Test
    fun `a verified email asks nothing`() {
        val contacts = RecoveryContacts("alice@example.net", emailVerified = true, phoneVerified = false)
        assertNull(contacts.promptAfterSignIn(smsEnabled = true))
        assertNull(contacts.promptAfterSignIn(smsEnabled = false))
    }

    /** A phone-only account (Cabalmail as someone's only email) is left alone when its phone recovers it. */
    @Test
    fun `a phone-only account is not asked when the verified phone recovers it`() {
        assertNull(
            RecoveryContacts(null, emailVerified = false, phoneVerified = true).promptAfterSignIn(smsEnabled = true),
        )
    }

    @Test
    fun `an account with no way back in is asked to add an email`() {
        // SMS off: the phone can't recover the account, verified or not.
        assertEquals(
            RecoveryEmailPrompt.Add,
            RecoveryContacts(null, emailVerified = false, phoneVerified = true).promptAfterSignIn(smsEnabled = false),
        )
        // SMS on, but the phone was never verified.
        assertEquals(
            RecoveryEmailPrompt.Add,
            RecoveryContacts(null, emailVerified = false, phoneVerified = false).promptAfterSignIn(smsEnabled = true),
        )
        // An empty address is no address.
        assertEquals(
            RecoveryEmailPrompt.Add,
            RecoveryContacts("", emailVerified = false, phoneVerified = false).promptAfterSignIn(smsEnabled = true),
        )
    }

    // The calls

    private class SignedIn : TokenStore {
        override fun readTokens(): AuthTokens =
            AuthTokens(
                idToken = "id",
                accessToken = "access-1",
                refreshToken = "refresh",
                tokenType = "Bearer",
                expiresAtEpochMillis = Long.MAX_VALUE,
            )

        override fun writeTokens(tokens: AuthTokens) = Unit

        override fun readUsername(): String = "alice"

        override fun writeUsername(username: String) = Unit

        override fun clear() = Unit
    }

    private class CognitoStub(
        vararg responses: Pair<HttpStatusCode, String>,
    ) {
        val targets = mutableListOf<String>()
        val bodies = mutableListOf<JsonObject>()
        private val queue = responses.toMutableList()

        val client =
            HttpClient(
                MockEngine { request ->
                    targets += request.headers["X-Amz-Target"].orEmpty().substringAfterLast('.')
                    bodies += Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    val (code, body) = queue.removeAt(0)
                    respond(body, code, headersOf(HttpHeaders.ContentType, "application/x-amz-json-1.1"))
                },
            )
    }

    private fun service(stub: CognitoStub) = CognitoAuthService("client-id", "us-east-1", stub.client, SignedIn())

    @Test
    fun `recovery contacts reads GetUser's attributes`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.OK to
                        """
                        {"Username": "alice", "UserAttributes": [
                          {"Name": "email", "Value": "alice@example.net"},
                          {"Name": "email_verified", "Value": "false"},
                          {"Name": "phone_number", "Value": "+15555550123"},
                          {"Name": "phone_number_verified", "Value": "true"}]}
                        """.trimIndent(),
                )

            val contacts = service(stub).recoveryContacts()

            assertEquals(RecoveryContacts("alice@example.net", emailVerified = false, phoneVerified = true), contacts)
            assertEquals(listOf("GetUser"), stub.targets)
            assertEquals(Json.parseToJsonElement("""{"AccessToken":"access-1"}"""), stub.bodies.single())
        }

    @Test
    fun `the writes send the contract's bodies`() =
        runTest {
            val stub = CognitoStub(HttpStatusCode.OK to "{}", HttpStatusCode.OK to "{}", HttpStatusCode.OK to "{}")
            val auth = service(stub)

            auth.setRecoveryEmail("alice@example.net")
            auth.sendRecoveryEmailCode()
            auth.verifyRecoveryEmail("424242")

            assertEquals(
                listOf("UpdateUserAttributes", "GetUserAttributeVerificationCode", "VerifyUserAttribute"),
                stub.targets,
            )
            assertEquals(
                Json.parseToJsonElement(
                    """{"AccessToken":"access-1","UserAttributes":[{"Name":"email","Value":"alice@example.net"}]}""",
                ),
                stub.bodies[0],
            )
            assertEquals(
                Json.parseToJsonElement("""{"AccessToken":"access-1","AttributeName":"email"}"""),
                stub.bodies[1],
            )
            assertEquals(
                Json.parseToJsonElement("""{"AccessToken":"access-1","AttributeName":"email","Code":"424242"}"""),
                stub.bodies[2],
            )
        }

    @Test
    fun `a wrong code comes back as Cognito's refusal`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.BadRequest to """{"__type":"CodeMismatchException","message":"Invalid code"}""",
                )

            val error = runCatching { service(stub).verifyRecoveryEmail("000000") }.exceptionOrNull()

            assertTrue(error is CabalmailException.ServerError && error.code == "CodeMismatchException", "got $error")
        }
}
