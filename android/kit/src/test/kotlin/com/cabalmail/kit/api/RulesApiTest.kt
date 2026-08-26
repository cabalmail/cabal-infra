package com.cabalmail.kit.api

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.models.Rule
import com.cabalmail.kit.models.RuleAction
import com.cabalmail.kit.models.RuleCondition
import com.cabalmail.kit.models.RuleField
import com.cabalmail.kit.models.RuleSet
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
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/**
 * Wire-level tests for the `/get_rules` / `/set_rules` pair backing the
 * mail-rules editor (`docs/1.x/user-mail-rules-plan.md`, Phase 4b).
 */
class RulesApiTest {
    private class FakeAuth : AuthService {
        override suspend fun signIn(
            username: String,
            password: String,
        ): SignInResult = SignInResult.SignedIn

        override suspend fun submitMfaCode(code: String) = Unit

        override suspend fun signUp(
            username: String,
            password: String,
            email: String?,
            phone: String?,
        ) = Unit

        override suspend fun confirmSignUp(
            username: String,
            code: String,
        ) = Unit

        override suspend fun resendConfirmationCode(username: String) = Unit

        override suspend fun forgotPassword(username: String) = Unit

        override suspend fun confirmForgotPassword(
            username: String,
            code: String,
            newPassword: String,
        ) = Unit

        override suspend fun signOut() = Unit

        override suspend fun currentIdToken(): String = "idtoken"

        override suspend fun forceRefreshedIdToken(): String = "idtoken"

        override fun currentUsername(): String? = "chris"

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
    }

    @Test
    fun `getRules decodes the wire shape`() =
        runTest {
            val body =
                """
                {"rules":[{"id":"r-0123456789ab","name":"Receipts","enabled":true,
                  "conditions":[{"field":"subject","value":"invoice"}],"action":"move",
                  "moveFolder":"Receipts","copyFolders":[],"flag":false,"markRead":false,
                  "forward":[],"reply":false,"replyBody":"","continueToNext":false}],
                 "version":3,"updatedAt":"2026-08-25T12:00:00+00:00"}
                """.trimIndent()
            val server = Server(HttpStatusCode.OK to body)

            val ruleSet = server.api.getRules()

            assertEquals(3, ruleSet.version)
            assertEquals(listOf("r-0123456789ab"), ruleSet.rules.map { it.id })
            assertEquals(RuleAction.MOVE, ruleSet.rules.single().action)
            val request = server.requests.single()
            assertEquals("GET", request.method.value)
            assertEquals("/v1/get_rules", request.url.encodedPath)
        }

    @Test
    fun `getRules maps a rule-less user to the empty set`() =
        runTest {
            val server = Server(HttpStatusCode.OK to """{"rules": [], "version": 0, "updatedAt": ""}""")

            assertEquals(RuleSet(), server.api.getRules())
        }

    @Test
    fun `setRules puts the full wire body and returns the new version`() =
        runTest {
            val response =
                """
                {"rules":[{"id":"r-0123456789ab","name":"A"}],"version":4,
                 "updatedAt":"2026-08-25T12:00:01+00:00","stripped":[],"warnings":[]}
                """.trimIndent()
            val server = Server(HttpStatusCode.OK to response)
            val rule =
                Rule(
                    id = "r-0123456789ab",
                    name = "A",
                    conditions = listOf(RuleCondition(RuleField.FROM, "aws")),
                    action = RuleAction.MOVE,
                    moveFolder = "Receipts",
                )

            val saved = server.api.setRules(listOf(rule), expectedVersion = 3)

            // The 200 body's extra stripped/warnings keys must not break the
            // decode; the version propagates to the next save.
            assertEquals(4, saved.version)
            val request = server.requests.single()
            assertEquals("PUT", request.method.value)
            assertEquals("/v1/set_rules", request.url.encodedPath)
            val payload = Json.parseToJsonElement(server.body(0)).jsonObject
            assertEquals(3, payload["expectedVersion"]?.jsonPrimitive?.content?.toInt())
            val rules = payload["rules"]!!.jsonArray
            val wireRule = rules.single().jsonObject
            assertEquals("r-0123456789ab", wireRule["id"]?.jsonPrimitive?.content)
            assertEquals("Receipts", wireRule["moveFolder"]?.jsonPrimitive?.content)
            // Every wire key rides along (whole-row replacement semantics).
            assertEquals(
                setOf(
                    "id",
                    "name",
                    "enabled",
                    "conditions",
                    "action",
                    "moveFolder",
                    "copyFolders",
                    "flag",
                    "markRead",
                    "forward",
                    "reply",
                    "replyBody",
                    "continueToNext",
                ),
                wireRule.keys,
            )
            assertEquals(
                "from",
                wireRule["conditions"]!!
                    .jsonArray[0]
                    .jsonObject["field"]
                    ?.jsonPrimitive
                    ?.content,
            )
        }

    @Test
    fun `a 409 surfaces as the typed conflict`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.Conflict to
                        """{"Error": "Rules changed on another device; reload.", "version": 9}""",
                )

            assertThrows<CabalmailException.RuleSetConflict> {
                server.api.setRules(emptyList(), expectedVersion = 2)
            }
        }

    @Test
    fun `a 400 stays an ordinary api error`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.BadRequest to
                        """{"errors": [{"rule": 0, "field": "name", "error": "Must be 1-100 characters."}]}""",
                )

            val error =
                assertThrows<CabalmailException.ApiError> {
                    server.api.setRules(listOf(Rule()), expectedVersion = 0)
                }
            assertEquals(400, error.httpStatus)
            assertNull(error as? CabalmailException.RuleSetConflict)
        }
}
