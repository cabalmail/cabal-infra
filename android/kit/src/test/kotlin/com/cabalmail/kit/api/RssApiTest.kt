package com.cabalmail.kit.api

import com.cabalmail.kit.CabalmailException
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssItemFilter
import com.cabalmail.kit.models.RssItemOrder
import com.cabalmail.kit.models.RssItemScope
import com.cabalmail.kit.models.RssItemStateChange
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssSubscriptionUpdate
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/**
 * Wire-level tests for the RSS endpoints (`docs/rss.md`), mirroring the
 * Apple kit's `ApiClientRssTests`: query shapes, body shapes, lenient
 * decoding, and the error envelope's code.
 */
class RssApiTest {
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

        fun body(index: Int) = Json.parseToJsonElement((requests[index].body as TextContent).text).jsonObject
    }

    private val catalogJson =
        """
        {"folders":[{"folder_id":"d1","parent_folder_id":"","name":"News","display_order":2,"default_filter":"all"}],
         "subscriptions":[{"subscription_id":"s1","feed_id":"f1","folder_id":"d1","custom_title":"",
           "ordering_mode":"oldest_first","default_open_mode":"article","default_styling":"native",
           "default_remote_content":"show","default_filter":"favorite","notifications_enabled":true,
           "read_watermark":"2026-01-01T00:00:00+00:00","data_store_uuid":"u1",
           "feed":{"feed_id":"f1","title":"Feed One","canonical_url":"https://example.com/feed",
                   "consecutive_failure_count":3,"last_error":"HTTP 503","some_future_field":true}}]}
        """.trimIndent()

    @Test
    fun `list subscriptions decodes the catalog, its enums, and the nested feed`() =
        runTest {
            val server = Server(HttpStatusCode.OK to catalogJson)

            val catalog = server.api.listSubscriptions()

            assertEquals(HttpMethod.Get, server.requests.single().method)
            assertEquals(
                "/v1/rss_list_subscriptions",
                server.requests
                    .single()
                    .url.encodedPath,
            )
            assertEquals(RssItemFilter.ALL, catalog.folders.single().defaultFilter)
            val sub = catalog.subscriptions.single()
            assertEquals(RssOrderingMode.OLDEST_FIRST, sub.orderingMode)
            assertEquals(RssRemoteContentMode.SHOW, sub.defaultRemoteContent)
            assertEquals(RssItemFilter.FAVORITE, sub.defaultFilter)
            assertTrue(sub.notificationsEnabled)
            assertEquals(3, sub.feed?.consecutiveFailureCount)
            assertEquals("Feed One", sub.displayTitle)
        }

    @Test
    fun `subscribe posts the url and folder and an error envelope surfaces its code`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """{"subscription":{"subscription_id":"s2","feed_id":"f2"},"existing":true}""",
                    HttpStatusCode.BadRequest to """{"Error":"That page has no feed","code":"not_a_feed"}""",
                )

            val result = server.api.subscribe("https://example.com", folderId = "d1")
            assertTrue(result.existing)
            assertEquals("s2", result.subscription.subscriptionId)
            assertEquals("https://example.com", server.body(0)["url"]?.jsonPrimitive?.content)
            assertEquals("d1", server.body(0)["folder_id"]?.jsonPrimitive?.content)

            val error = assertThrows<CabalmailException.ApiError> { server.api.subscribe("https://example.org") }
            assertEquals("not_a_feed", error.code)
            assertEquals("That page has no feed", error.message)
            assertNull(server.body(1)["folder_id"])
        }

    @Test
    fun `the three forms of list items send exactly their own parameters`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to """{"items":[{"feed_id":"f1","sort_key":"k1"}],"next_cursor":"c2"}""",
                    HttpStatusCode.OK to """{"items":[],"next_since":"fk","has_more":true}""",
                    HttpStatusCode.OK to
                        """{"states":[{"feed_id":"f1","sort_key":"k1","is_read":true}],
                           "next_state_since":"st","has_more":false}""",
                    HttpStatusCode.OK to """{"items":[]}""",
                )

            val page =
                server.api.listItems(
                    RssItemScope.Folder("d1"),
                    filter = RssItemFilter.UNREAD,
                    order = RssItemOrder.OLDEST,
                    limit = 20,
                    cursor = "c1",
                )
            val sync = server.api.syncItems("s1", since = "", limit = 100)
            val states = server.api.syncItemStates("s1", since = "c0", limit = 100)
            server.api.listItems(RssItemScope.All)

            val listing = server.requests[0].url.parameters
            assertEquals(setOf("folder_id", "filter", "order", "limit", "cursor"), listing.names())
            assertEquals("unread", listing["filter"])
            assertEquals("oldest", listing["order"])
            assertEquals("20", listing["limit"])
            assertEquals("c2", page.nextCursor)

            val sinceQuery = server.requests[1].url.parameters
            assertEquals(setOf("subscription_id", "since", "limit"), sinceQuery.names())
            assertEquals("", sinceQuery["since"])
            assertEquals("fk", sync.nextSince)
            assertTrue(sync.hasMore)

            val stateQuery = server.requests[2].url.parameters
            assertEquals(setOf("subscription_id", "state_since", "limit"), stateQuery.names())
            assertEquals("c0", stateQuery["state_since"])
            assertEquals("st", states.nextSince)
            assertTrue(states.states.single().isRead)

            // All feeds: no scope key and no cursor.
            assertEquals(
                setOf("filter", "order", "limit"),
                server.requests[3]
                    .url.parameters
                    .names(),
            )
            assertEquals("", page.items.single().subscriptionId)
        }

    @Test
    fun `set item state omits null flags and mark all read posts the scope`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to """{"updated":2}""",
                    HttpStatusCode.OK to """{"subscriptions":1,"flipped":0,"read_watermark":"2026-02-02T00:00:00Z"}""",
                    HttpStatusCode.OK to """{"subscriptions":3,"flipped":1,"read_watermark":"w"}""",
                )

            val updated =
                server.api.setItemState(
                    listOf(
                        RssItemStateChange("f1", "k1", isRead = true),
                        RssItemStateChange("f1", "k2", isFavorite = false),
                    ),
                )
            val marked = server.api.markAllRead(RssItemScope.Subscription("s1"))
            server.api.markAllRead(RssItemScope.All)

            assertEquals(2, updated)
            val items = server.body(0)["items"]!!.jsonArray
            assertNull(items[0].jsonObject["is_favorite"])
            assertEquals("true", items[0].jsonObject["is_read"]?.jsonPrimitive?.content)
            assertNull(items[1].jsonObject["is_read"])
            assertEquals("false", items[1].jsonObject["is_favorite"]?.jsonPrimitive?.content)
            assertEquals("s1", server.body(1)["subscription_id"]?.jsonPrimitive?.content)
            assertEquals("2026-02-02T00:00:00Z", marked.readWatermark)
            assertTrue(server.body(2).isEmpty())
        }

    @Test
    fun `update subscription and folder are PUTs carrying only the changed fields`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to
                        """{"subscription":{"subscription_id":"s1","feed_id":"f1","default_remote_content":"show"}}""",
                    HttpStatusCode.OK to """{"folder":{"folder_id":"d1","name":"News","default_filter":"all"}}""",
                )

            val sub =
                server.api.updateSubscription(
                    "s1",
                    RssSubscriptionUpdate(folderId = "", defaultRemoteContent = RssRemoteContentMode.HIDE),
                )
            val folder = server.api.updateRssFolder("d1", RssFolderUpdate(defaultFilter = RssItemFilter.ALL))

            assertEquals(HttpMethod.Put, server.requests[0].method)
            assertEquals(setOf("subscription_id", "folder_id", "default_remote_content"), server.body(0).keys)
            assertEquals("hide", server.body(0)["default_remote_content"]?.jsonPrimitive?.content)
            assertEquals(RssRemoteContentMode.SHOW, sub.defaultRemoteContent)
            assertEquals(HttpMethod.Put, server.requests[1].method)
            assertEquals(setOf("folder_id", "default_filter"), server.body(1).keys)
            assertEquals(RssItemFilter.ALL, folder.defaultFilter)
        }

    @Test
    fun `opml round-trips through the two endpoints`() =
        runTest {
            val server =
                Server(
                    HttpStatusCode.OK to """{"opml":"<opml/>","filename":"cabalmail.opml"}""",
                    HttpStatusCode.OK to
                        """{"created":2,"existing":1,"folders_created":1,
                           "failed":[{"url":"https://x","code":"not_https","Error":"Not served over https"}]}""",
                )

            val export = server.api.exportOpml()
            val imported = server.api.importOpml("<opml/>")

            assertEquals("cabalmail.opml", export.filename)
            assertEquals("<opml/>", server.body(1)["opml"]?.jsonPrimitive?.content)
            assertEquals(2, imported.created)
            assertEquals("Not served over https", imported.failed.single().message)
            assertFalse(server.body(1).containsKey("folder_id"))
        }
}
