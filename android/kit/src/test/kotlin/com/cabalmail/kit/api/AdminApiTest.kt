package com.cabalmail.kit.api

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.CodeDelivery
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.auth.SignUpResult
import com.cabalmail.kit.models.DomainAllowance
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.time.Instant

/**
 * Wire-level tests for the administration endpoints behind the native Users
 * screen (auth parity plan, C2), mirroring the Apple kit's
 * `AdminApiClientTests`. Shapes are the Lambdas':
 * `lambda/api/{list_users,confirm_user,enable_user,disable_user,delete_user,
 * list_user_domain_access,set_user_domain_access}/function.py`.
 */
class AdminApiTest {
    private class FakeAuth : AuthService {
        override suspend fun signIn(
            username: String,
            password: String,
        ): SignInResult = SignInResult.SignedIn

        override suspend fun submitMfaCode(code: String) = Unit

        override suspend fun signUp(
            username: String,
            password: String,
            email: String,
            phone: String?,
            invitationCode: String?,
        ): SignUpResult = SignUpResult.Confirmed

        override suspend fun confirmSignUp(
            username: String,
            code: String,
        ) = Unit

        override suspend fun resendConfirmationCode(username: String): CodeDelivery? = null

        override suspend fun forgotPassword(username: String) = Unit

        override suspend fun confirmForgotPassword(
            username: String,
            code: String,
            newPassword: String,
        ) = Unit

        override suspend fun signOut() = Unit

        override suspend fun currentIdToken(): String = "idtoken"

        override suspend fun forceRefreshedIdToken(): String = "idtoken"

        override fun currentUsername(): String? = "admin"

        override fun currentTokens(): AuthTokens? = null
    }

    private class Server(
        vararg responses: Pair<HttpStatusCode, String>,
    ) {
        val requests = mutableListOf<HttpRequestData>()
        private val queue = responses.toMutableList()

        val api =
            ApiClient(
                baseUrl = "https://api.example.com/v1",
                host = "imap.example.com",
                authService = FakeAuth(),
                httpClient =
                    HttpClient(
                        MockEngine { request ->
                            requests += request
                            val (code, body) = queue.removeAt(0)
                            respond(
                                content = body,
                                status = code,
                                headers = headersOf(HttpHeaders.ContentType, "application/json"),
                            )
                        },
                    ),
            )

        fun body(index: Int): String = (requests[index].body as TextContent).text

        fun bodyField(
            index: Int,
            key: String,
        ): JsonPrimitive? = Json.parseToJsonElement(body(index)).jsonObject[key]?.jsonPrimitive
    }

    private val ok = HttpStatusCode.OK to """{"status":"ok"}"""

    @Test
    fun `listUsers decodes the lambda envelope`() =
        runTest {
            val body =
                """
                {"Users": [
                  {"username": "alice", "status": "CONFIRMED", "enabled": true,
                   "created": "2024-01-02T03:04:05.123456+00:00", "osid": "2001"},
                  {"username": "bob", "status": "UNCONFIRMED", "enabled": true,
                   "created": "2024-01-02T03:04:05+00:00", "osid": ""},
                  {"username": "carol", "status": "FORCE_CHANGE_PASSWORD", "enabled": false}
                ]}
                """.trimIndent()
            val server = Server(HttpStatusCode.OK to body)

            val users = server.api.listUsers()

            assertEquals(listOf("alice", "bob", "carol"), users.map { it.username })
            assertEquals("2001", users[0].osid)
            assertNull(users[1].osid, "an empty osid reads as none assigned")
            assertEquals(Instant.ofEpochSecond(1_704_164_645, 123_456_000), users[0].created)
            assertEquals(Instant.ofEpochSecond(1_704_164_645), users[1].created)
            assertNull(users[2].created)
            assertFalse(users[2].enabled)
            assertEquals(listOf(false, true, true), users.map { it.isPending })
            val request = server.requests.single()
            assertEquals("GET", request.method.value)
            assertEquals("/v1/list_users", request.url.encodedPath)
            assertEquals("idtoken", request.headers[HttpHeaders.Authorization])
        }

    @Test
    fun `listUsers refuses a reply without the envelope`() =
        runTest {
            val server = Server(HttpStatusCode.OK to "{}")
            assertThrows<CabalmailException.DecodingError> { server.api.listUsers() }
        }

    /** The server is the authority: a 403 surfaces with the Lambda's own sentence. */
    @Test
    fun `a non-admin gets a 403 with the server's sentence`() =
        runTest {
            val server = Server(HttpStatusCode.Forbidden to """{"Error":"Admin access required"}""")

            val error = assertThrows<CabalmailException.ApiError> { server.api.listUsers() }

            assertEquals(403, error.httpStatus)
            assertEquals("Admin access required", error.message)
        }

    @Test
    fun `user actions send the username to their endpoint`() =
        runTest {
            val server = Server(ok, ok, ok, ok)

            server.api.confirmUser("alice")
            server.api.enableUser("bob")
            server.api.disableUser("carol")
            server.api.deleteUser("dave")

            assertEquals(listOf("PUT", "PUT", "PUT", "DELETE"), server.requests.map { it.method.value })
            assertEquals(
                listOf("/v1/confirm_user", "/v1/enable_user", "/v1/disable_user", "/v1/delete_user"),
                server.requests.map { it.url.encodedPath },
            )
            assertEquals(
                listOf("alice", "bob", "carol", "dave"),
                (0..3).map { server.bodyField(it, "username")?.content },
            )
        }

    @Test
    fun `deleting your own account surfaces the server's refusal`() =
        runTest {
            val server = Server(HttpStatusCode.BadRequest to """{"Error":"Cannot delete your own account"}""")

            val error = assertThrows<CabalmailException.ApiError> { server.api.deleteUser("admin") }

            assertEquals(400, error.httpStatus)
            assertEquals("Cannot delete your own account", error.message)
        }

    @Test
    fun `listUserDomainAccess decodes the allow list`() =
        runTest {
            val body =
                """{"Allowances":[{"user":"alice","domain":"cabalmail.example"},""" +
                    """{"user":"bob","domain":"b.example"}]}"""
            val server = Server(HttpStatusCode.OK to body)

            val allowances = server.api.listUserDomainAccess()

            assertEquals(
                listOf(DomainAllowance("alice", "cabalmail.example"), DomainAllowance("bob", "b.example")),
                allowances,
            )
            assertEquals(
                "/v1/list_user_domain_access",
                server.requests
                    .single()
                    .url.encodedPath,
            )
        }

    /**
     * `allowed` has to reach the Lambda as a JSON boolean: it refuses anything
     * else with "Body requires user (str), domain (str), allowed (bool)."
     */
    @Test
    fun `setUserDomainAccess sends a boolean allowed`() =
        runTest {
            val server = Server(ok, ok)

            server.api.setUserDomainAccess("alice", "cabalmail.example", allowed = true)
            server.api.setUserDomainAccess("alice", "cabalmail.example", allowed = false)

            assertEquals(listOf("PUT", "PUT"), server.requests.map { it.method.value })
            assertEquals("/v1/set_user_domain_access", server.requests[0].url.encodedPath)
            val granted = server.bodyField(0, "allowed")
            assertTrue(granted?.isString == false && granted.content == "true", "allowed is the JSON literal true")
            assertEquals("false", server.bodyField(1, "allowed")?.content)
            assertEquals("alice", server.bodyField(0, "user")?.content)
            assertEquals("cabalmail.example", server.bodyField(0, "domain")?.content)
        }
}
