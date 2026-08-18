package com.cabalmail.kit.api

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.models.ComposeFields
import com.cabalmail.kit.models.NavState
import com.cabalmail.kit.models.PreferencesUpdate
import com.cabalmail.kit.models.SendOutcome
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ApiClientTest {
    private class FakeAuth : AuthService {
        var refreshCount = 0

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

        override suspend fun currentIdToken(): String = "token-1"

        override suspend fun forceRefreshedIdToken(): String {
            refreshCount += 1
            return "token-2"
        }

        override fun currentUsername(): String? = "chris"

        override fun currentTokens(): AuthTokens? = null
    }

    private class Server(
        vararg responses: Pair<HttpStatusCode, String>,
    ) {
        val requests = mutableListOf<HttpRequestData>()
        private val queue = responses.toMutableList()
        val auth = FakeAuth()

        val api =
            ApiClient(
                baseUrl = "https://api.example.com/v1",
                host = "imap.example.com",
                authService = auth,
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

    private val envelopeJson =
        """
        {
          "id": 101, "date": "2024-01-15 10:30:45+00:00", "subject": "Hi",
          "from": ["\"Ann\" <ann@ex.com>"], "to": ["me@ex.com"], "cc": [],
          "flags": ["\\Seen"],
          "struct": [["text", "plain"], ["application", "pdf", "attachment"]],
          "priority": ["priority-1"],
          "message_id": ["<a@x>"], "in_reply_to": [], "references": ["<r@x>"],
          "auth_results": {"spf": "pass", "dkim": "pass", "dmarc": "pass"}
        }
        """.trimIndent()

    @Test
    fun `authorization header carries the raw id token with no bearer prefix`() =
        runTest {
            val server = Server(HttpStatusCode.OK to """{"Items": []}""")

            server.api.listAddresses()

            assertEquals("token-1", server.requests.single().headers["Authorization"])
        }

    @Test
    fun `a 401 is replayed once with a force-refreshed token`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.Unauthorized to """{"message": "expired"}""",
                    HttpStatusCode.OK to """{"Items": [{"address": "a@b.c"}]}""",
                )

            val addresses = server.api.listAddresses()

            assertEquals(1, addresses.size)
            assertEquals(1, server.auth.refreshCount)
            assertEquals("token-2", server.requests[1].headers["Authorization"])
        }

    @Test
    fun `a second 401 surfaces as AuthExpired`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.Unauthorized to "{}",
                    HttpStatusCode.Unauthorized to "{}",
                )

            val exception = runCatching { server.api.listAddresses() }.exceptionOrNull()

            assertTrue(exception is CabalmailException.AuthExpired)
        }

    @Test
    fun `listEnvelopes sends the json-array id string and decodes the uid-keyed map`() =
        runTest {
            val server = Server(HttpStatusCode.OK to """{"envelopes": {"101": $envelopeJson}}""")

            val envelopes = server.api.listEnvelopes("Archive/2024", listOf(101L, 102L))

            val url = server.requests.single().url
            assertEquals("[101,102]", url.parameters["ids"])
            assertEquals("Archive/2024", url.parameters["folder"])
            val envelope = envelopes.getValue(101L)
            assertTrue(envelope.hasAttachments)
            assertTrue(envelope.isHighPriority)
            assertTrue(envelope.isSeen)
            assertEquals("pass", envelope.authResults?.dmarc)
        }

    @Test
    fun `empty id list short-circuits without a request`() =
        runTest {
            val server = Server()

            assertTrue(server.api.listEnvelopes("INBOX", emptyList()).isEmpty())
            assertTrue(server.requests.isEmpty())
        }

    @Test
    fun `search filters go on the wire as flag params and the cursor round-trips`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """
                        {"envelopes": [$envelopeJson], "total_estimate": 1,
                         "next_cursor": "abc", "folders_searched": ["INBOX"], "truncated": false}
                        """.trimIndent(),
                )

            val result =
                server.api.searchEnvelopes(
                    text = "invoice",
                    filters =
                        com.cabalmail.kit.models
                            .SearchFilters(unread = true, hasAttachment = true),
                    cursor = "prev-cursor",
                )

            val url = server.requests.single().url
            assertEquals("1", url.parameters["unread"])
            assertEquals("1", url.parameters["has_attachment"])
            assertNull(url.parameters["flagged"])
            assertEquals("prev-cursor", url.parameters["cursor"])
            assertEquals("abc", result.nextCursor)
            assertEquals(101L, result.envelopes.single().id)
        }

    @Test
    fun `listMessages encodes the REVERSE sort order with trailing space`() =
        runTest {
            val server = Server(HttpStatusCode.OK to """{"message_ids": [3, 2, 1], "total": 3}""")

            val page = server.api.listMessages("INBOX", sortField = "DATE", descending = true)

            assertEquals(
                "REVERSE ",
                server.requests
                    .single()
                    .url.parameters["sort_order"],
            )
            assertEquals(listOf(3L, 2L, 1L), page.messageIds)
        }

    @Test
    fun `bulk partial results carry the failed ids`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """{"status": "partial", "flagged_ids": [1], "failed_ids": [2]}""",
                )

            val result = server.api.setFlag("INBOX", listOf(1L, 2L), "\\Seen", set = true)

            assertTrue(result.isPartial)
            assertEquals(listOf(2L), result.failedIds)
            assertTrue(server.body(0).contains("\"op\":\"set\""))
        }

    @Test
    fun `send maps 409 to DuplicateInFlight and 200 to Submitted`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.Conflict to
                        """{"status": "duplicate_in_flight", "message": "in flight"}""",
                    HttpStatusCode.OK to """{"status": "submitted"}""",
                )
            val fields = ComposeFields(sender = "a@b.c", toList = listOf("x@y.z"))

            assertEquals(SendOutcome.DuplicateInFlight, server.api.send(fields))
            assertEquals(SendOutcome.Submitted(duplicate = false), server.api.send(fields))
            val body = server.body(1)
            assertTrue(body.contains("\"to_list\":[\"x@y.z\"]"))
            assertTrue(body.contains("\"cc_list\":[]"))
            assertTrue(body.contains("\"host\":"))
        }

    @Test
    fun `saveDraft returns nullable uidplus coordinates`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """{"status": "saved", "uid": 7, "uidvalidity": 9, "replaced": true}""",
                )

            val result =
                server.api.saveDraft(
                    ComposeFields(sender = "a@b.c"),
                    replacesUid = 5L,
                    replacesUidValidity = 9L,
                )

            assertEquals(7L, result.uid)
            assertTrue(result.replaced)
            assertTrue(server.body(0).contains("\"replaces_uid\":5"))
            assertTrue(server.body(0).contains("\"op\":\"save\""))
        }

    @Test
    fun `empty nav state decodes to null`() =
        runTest {
            val server = Server(HttpStatusCode.OK to "{}")

            assertNull(server.api.getNavState())
        }

    @Test
    fun `setNavState never sends updated_at`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """{"folder": "INBOX", "client_id": "c1", "updated_at": 172390}""",
                )

            val stored =
                server.api.setNavState(
                    NavState(folder = "INBOX", clientId = "c1", uid = 12L, updatedAt = 999L),
                )

            val body = server.body(0)
            assertFalse(body.contains("updated_at"))
            assertTrue(body.contains("\"uid\":12"))
            assertEquals(172390L, stored.updatedAt)
        }

    @Test
    fun `preferences update sends only non-null keys`() =
        runTest {
            val server = Server(HttpStatusCode.OK to """{"app": {}}""")

            server.api.setPreferences(PreferencesUpdate(app = mapOf("mark_as_read" to "manual")))

            assertEquals("""{"app":{"mark_as_read":"manual"}}""", server.body(0))
        }

    @Test
    fun `maintenance 503 maps to the retryable Maintenance exception`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.ServiceUnavailable to
                        """{"status": "maintenance", "message": "back soon", "retry_after": 300}""",
                )

            val exception = runCatching { server.api.listFolders() }.exceptionOrNull()

            assertTrue(exception is CabalmailException.Maintenance)
        }

    @Test
    fun `non-200 success codes are accepted`() =
        runTest {
            val server = Server(HttpStatusCode.Created to """{"address": "a@b.example-mail.com"}""")

            val address = server.api.newAddress("a", "b", "example-mail.com", "")

            assertEquals("a@b.example-mail.com", address)
        }
}
