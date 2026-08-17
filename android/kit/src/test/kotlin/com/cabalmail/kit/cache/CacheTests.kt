package com.cabalmail.kit.cache

import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.models.Envelope
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class InMemoryEnvelopeCacheTest {
    private fun envelope(uid: Long) = Envelope(id = uid, subject = "s$uid")

    @Test
    fun `read returns only cached uids and write round-trips`() =
        runTest {
            val cache = InMemoryEnvelopeCache()
            cache.write("INBOX", listOf(envelope(1), envelope(2)))

            val hit = cache.read("INBOX", listOf(1, 2, 3))

            assertEquals(setOf(1L, 2L), hit.keys)
            assertEquals("s1", hit[1L]?.subject)
            assertTrue(cache.read("Archive", listOf(1)).isEmpty())
        }

    @Test
    fun `uidvalidity mismatch clears the folder but not others`() =
        runTest {
            val cache = InMemoryEnvelopeCache()
            cache.reconcile("INBOX", 9)
            cache.write("INBOX", listOf(envelope(1)))
            cache.write("Archive", listOf(envelope(7)))

            cache.reconcile("INBOX", 10)

            assertTrue(cache.read("INBOX", listOf(1)).isEmpty())
            assertEquals(setOf(7L), cache.read("Archive", listOf(7)).keys)
        }

    @Test
    fun `same uidvalidity keeps entries`() =
        runTest {
            val cache = InMemoryEnvelopeCache()
            cache.reconcile("INBOX", 9)
            cache.write("INBOX", listOf(envelope(1)))

            cache.reconcile("INBOX", 9)

            assertEquals(setOf(1L), cache.read("INBOX", listOf(1)).keys)
        }

    @Test
    fun `lru eviction drops the least recently used first`() =
        runTest {
            val cache = InMemoryEnvelopeCache(maxEntries = 2)
            cache.write("INBOX", listOf(envelope(1), envelope(2)))
            // Touch 1 so 2 becomes the eviction candidate.
            cache.read("INBOX", listOf(1))

            cache.write("INBOX", listOf(envelope(3)))

            assertEquals(setOf(1L, 3L), cache.read("INBOX", listOf(1, 2, 3)).keys)
        }
}

class BodyCacheTest {
    @TempDir
    lateinit var dir: File

    @Test
    fun `write then read round-trips and remove deletes`() =
        runTest {
            val cache = BodyCache(dir)
            cache.write("INBOX", 1, """{"body": "hello"}""")

            assertEquals("""{"body": "hello"}""", cache.read("INBOX", 1))
            assertNull(cache.read("INBOX", 2))
            assertNull(cache.read("Trash", 1))

            cache.remove("INBOX", 1)
            assertNull(cache.read("INBOX", 1))
        }

    @Test
    fun `eviction removes oldest entries once over the byte cap`() =
        runTest {
            var now = 1_000L
            val cache = BodyCache(dir, maxBytes = 25, clock = { now })
            cache.write("INBOX", 1, "aaaaaaaaaa")
            now += 10_000
            cache.write("INBOX", 2, "bbbbbbbbbb")
            now += 10_000

            cache.write("INBOX", 3, "cccccccccc")

            assertNull(cache.read("INBOX", 1))
            assertEquals("bbbbbbbbbb", cache.read("INBOX", 2))
            assertEquals("cccccccccc", cache.read("INBOX", 3))
        }
}

class AddressRepositoryTest {
    private object NoAuth : AuthService {
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

        override suspend fun currentIdToken(): String = "t"

        override suspend fun forceRefreshedIdToken(): String = "t"

        override fun currentUsername(): String? = null

        override fun currentTokens(): AuthTokens? = null
    }

    @Test
    fun `refresh sorts favorites first and mutations re-fetch`() =
        runTest {
            var paths = mutableListOf<String>()
            val responses =
                ArrayDeque(
                    listOf(
                        // initial refresh
                        """{"Items": [{"address": "b@x.y"}, {"address": "a@x.y", "favorite": true}]}""",
                        // setFavorite PUT
                        """{"address": "b@x.y", "favorite": true}""",
                        // refresh after mutation
                        """{"Items": [{"address": "b@x.y", "favorite": true}]}""",
                    ),
                )
            val client =
                HttpClient(
                    MockEngine { request ->
                        paths += request.url.encodedPath
                        respond(
                            content = responses.removeFirst(),
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    },
                )
            val repository =
                AddressRepository(ApiClient("https://api.example.com", "imap.example.com", NoAuth, client))

            val initial = repository.refresh()
            assertEquals(listOf("a@x.y", "b@x.y"), initial.map { it.address })

            repository.setFavorite("b@x.y", true)

            assertEquals(listOf("/set_favorite", "/list"), paths.drop(1))
            assertEquals(listOf("b@x.y"), repository.addresses.value?.map { it.address })
        }
}
