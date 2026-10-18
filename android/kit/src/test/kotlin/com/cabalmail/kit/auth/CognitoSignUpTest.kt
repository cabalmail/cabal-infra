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
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * The sign-up calls against the contract in `docs/auth.md` ("Sign-up"),
 * which the webmail and the Apple kit already follow: what `SignUp`,
 * `ConfirmSignUp` and `ResendConfirmationCode` send, how the reply says
 * whether a code is coming, and how `check_invite`'s two refusals come back
 * (auth parity plan, B1).
 */
class CognitoSignUpTest {
    private class CognitoStub(
        vararg responses: Pair<HttpStatusCode, String>,
    ) {
        val targets = mutableListOf<String>()
        val bodies = mutableListOf<JsonObject>()
        private val queue = responses.toMutableList()

        val client =
            HttpClient(
                MockEngine { request ->
                    targets += request.headers["X-Amz-Target"].orEmpty()
                    bodies += Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    val (code, body) = queue.removeAt(0)
                    respond(
                        content = body,
                        status = code,
                        headers = headersOf(HttpHeaders.ContentType, "application/x-amz-json-1.1"),
                    )
                },
            )
    }

    private object NoTokens : TokenStore {
        override fun readTokens(): AuthTokens? = null

        override fun writeTokens(tokens: AuthTokens) = Unit

        override fun readUsername(): String? = null

        override fun writeUsername(username: String) = Unit

        override fun clear() = Unit
    }

    private fun service(stub: CognitoStub) = CognitoAuthService("client-id", "us-east-1", stub.client, NoTokens)

    private val confirmedReply = HttpStatusCode.OK to """{"UserConfirmed": true, "UserSub": "sub-1"}"""

    private fun triggerRefusal(text: String) =
        HttpStatusCode.BadRequest to
            """
            {"__type": "com.amazonaws.cognito.identity.model#UserLambdaValidationException",
             "message": "PreSignUp failed with error $text."}
            """.trimIndent()

    private fun nameValues(vararg pairs: Pair<String, String>) =
        buildJsonArray {
            pairs.forEach { (name, value) ->
                addJsonObject {
                    put("Name", name)
                    put("Value", value)
                }
            }
        }

    // SignUp request

    @Test
    fun `sign-up sends the contract's body`() =
        runTest {
            val stub = CognitoStub(confirmedReply)

            service(stub).signUp("alice", "hunter2", "alice@example.net", null, "OPEN-SESAME")

            assertEquals("AWSCognitoIdentityProviderService.SignUp", stub.targets.single())
            val body = stub.bodies.single()
            assertEquals("\"client-id\"", body["ClientId"].toString())
            assertEquals("\"alice\"", body["Username"].toString())
            assertEquals("\"hunter2\"", body["Password"].toString())
            assertEquals(
                nameValues("preferred_username" to "alice", "email" to "alice@example.net"),
                body["UserAttributes"],
            )
            // Validation data, not a user attribute: check_invite reads it
            // there, and it is never stored on the user.
            assertEquals(nameValues("invitationCode" to "OPEN-SESAME"), body["ValidationData"])
        }

    @Test
    fun `no invitation code is still sent, empty`() =
        runTest {
            val stub = CognitoStub(confirmedReply)

            service(stub).signUp("alice", "pw", "alice@example.net", null, null)

            assertEquals(nameValues("invitationCode" to ""), stub.bodies.single()["ValidationData"])
        }

    @Test
    fun `a phone is sent only when given`() =
        runTest {
            val stub = CognitoStub(confirmedReply, confirmedReply)
            val auth = service(stub)

            auth.signUp("alice", "pw", "alice@example.net", "+15555550123", null)
            auth.signUp("bob", "pw", "bob@example.net", "", null)

            assertEquals(
                nameValues(
                    "preferred_username" to "alice",
                    "email" to "alice@example.net",
                    "phone_number" to "+15555550123",
                ),
                stub.bodies[0]["UserAttributes"],
            )
            assertEquals(
                nameValues("preferred_username" to "bob", "email" to "bob@example.net"),
                stub.bodies[1]["UserAttributes"],
            )
        }

    // SignUp reply

    @Test
    fun `a code delivery means a confirmation code is coming`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.OK to
                        """
                        {"UserConfirmed": false, "UserSub": "sub-1", "CodeDeliveryDetails":
                          {"AttributeName": "phone_number", "DeliveryMedium": "SMS", "Destination": "+*******0123"}}
                        """.trimIndent(),
                    HttpStatusCode.OK to
                        """
                        {"UserConfirmed": false, "CodeDeliveryDetails":
                          {"AttributeName": "email", "DeliveryMedium": "EMAIL", "Destination": "a***@e***"}}
                        """.trimIndent(),
                )
            val auth = service(stub)

            assertEquals(
                SignUpResult.ConfirmationCodeSent(CodeDelivery(CodeDelivery.Medium.PHONE, "+*******0123")),
                auth.signUp("alice", "pw", "alice@example.net", "+15555550123", null),
            )
            assertEquals(
                SignUpResult.ConfirmationCodeSent(CodeDelivery(CodeDelivery.Medium.EMAIL, "a***@e***")),
                auth.signUp("bob", "pw", "bob@example.net", null, null),
            )
        }

    /**
     * With SMS off, `check_invite` confirms the account itself and Cognito
     * sends no code: there is nothing to ask the user for.
     */
    @Test
    fun `no code delivery means the account is already confirmed`() =
        runTest {
            val result = service(CognitoStub(confirmedReply)).signUp("alice", "pw", "alice@example.net", null, null)

            assertEquals(SignUpResult.Confirmed, result)
        }

    // check_invite refusals

    @Test
    fun `a refused invitation code throws its own error`() =
        runTest {
            val stub = CognitoStub(triggerRefusal("Invalid invitation code."))

            val error =
                runCatching { service(stub).signUp("alice", "pw", "alice@example.net", null, "WRONG") }
                    .exceptionOrNull()

            assertTrue(error is CabalmailException.InvalidInvitationCode, "got $error")
            assertEquals("Invalid invitation code.", error?.message)
        }

    /**
     * A refused username is the same exception. It keeps the trigger's own
     * sentence, which the screens show as written.
     */
    @Test
    fun `a refused username keeps the trigger's sentence`() =
        runTest {
            val stub = CognitoStub(triggerRefusal("That username is reserved. Choose another."))

            val error =
                runCatching { service(stub).signUp("postmaster", "pw", "a@example.net", null, "OK") }
                    .exceptionOrNull() as CabalmailException.ServerError

            assertEquals("UserLambdaValidationException", error.code)
            assertEquals("That username is reserved. Choose another.", error.message)
        }

    @Test
    fun `other cognito refusals pass through`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.BadRequest to
                        """{"__type": "UsernameExistsException", "message": "User already exists"}""",
                )

            val error =
                runCatching { service(stub).signUp("alice", "pw", "alice@example.net", null, null) }
                    .exceptionOrNull() as CabalmailException.ServerError

            assertEquals("UsernameExistsException", error.code)
            assertEquals("User already exists", error.message)
        }

    // Confirm and resend

    @Test
    fun `confirm sign-up sends the code`() =
        runTest {
            val stub = CognitoStub(HttpStatusCode.OK to "{}")

            service(stub).confirmSignUp("alice", "123456")

            assertEquals("AWSCognitoIdentityProviderService.ConfirmSignUp", stub.targets.single())
            assertEquals(
                Json.parseToJsonElement("""{"ClientId":"client-id","Username":"alice","ConfirmationCode":"123456"}"""),
                stub.bodies.single(),
            )
        }

    @Test
    fun `resend says where the new code went`() =
        runTest {
            val stub =
                CognitoStub(
                    HttpStatusCode.OK to
                        """
                        {"CodeDeliveryDetails":
                          {"AttributeName": "email", "DeliveryMedium": "EMAIL", "Destination": "a***@e***"}}
                        """.trimIndent(),
                    HttpStatusCode.OK to "{}",
                )
            val auth = service(stub)

            assertEquals(CodeDelivery(CodeDelivery.Medium.EMAIL, "a***@e***"), auth.resendConfirmationCode("alice"))
            assertEquals("AWSCognitoIdentityProviderService.ResendConfirmationCode", stub.targets[0])
            assertEquals(Json.parseToJsonElement("""{"ClientId":"client-id","Username":"alice"}"""), stub.bodies[0])
            assertNull(auth.resendConfirmationCode("alice"))
        }
}
