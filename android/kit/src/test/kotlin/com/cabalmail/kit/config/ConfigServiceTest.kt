package com.cabalmail.kit.config

import app.cash.turbine.test
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException

class ConfigServiceTest {
    // Shaped exactly like terraform/infra/modules/app/templates/config.js.tftpl,
    // including the keys the client does not (yet) consume — decoding must
    // tolerate them.
    private val sampleJson =
        """
        {
          "control_domain": "admin.example.com",
          "domains": [
            {
              "domain": "example-mail.com",
              "arn": "arn:aws:route53:::hostedzone/Z0000000000000000000",
              "zone_id": "Z0000000000000000000",
              "name_servers": ["ns-1.example.org", "ns-2.example.org"]
            }
          ],
          "invokeUrl": "https://api.example.com/v1",
          "invitation_required": true,
          "sms_enabled": false,
          "monitoring": false,
          "cognitoConfig": {
            "region": "us-east-1",
            "poolData": {
              "UserPoolId": "us-east-1_AbCdEfGhI",
              "ClientId": "1234567890abcdefghijklmnop"
            },
            "enrollClientId": "qponmlkjihgfedcba0987654321"
          }
        }
        """.trimIndent()

    private class InMemoryConfigCache(
        var stored: String? = null,
    ) : ConfigCache {
        override suspend fun read(): String? = stored

        override suspend fun write(raw: String) {
            stored = raw
        }
    }

    private fun clientReturning(
        body: String,
        status: HttpStatusCode = HttpStatusCode.OK,
    ): HttpClient =
        HttpClient(
            MockEngine {
                respond(
                    content = body,
                    status = status,
                    headers = headersOf(HttpHeaders.ContentType, "application/json"),
                )
            },
        )

    @Test
    fun `refresh decodes the wire shape and exposes the derived accessors`() =
        runTest {
            val cache = InMemoryConfigCache()
            val service = ConfigService("admin.example.com", clientReturning(sampleJson), cache)

            val config = service.refresh()

            assertEquals("https://api.example.com/v1", config.apiUrl)
            assertEquals("admin.example.com", config.host)
            assertEquals("us-east-1_AbCdEfGhI", config.cognitoUserPoolId)
            assertEquals("1234567890abcdefghijklmnop", config.cognitoClientId)
            assertEquals(listOf("example-mail.com"), config.mailDomains)
            assertEquals("us-east-1", config.cognito.region)
            // The raw payload — not a re-serialization — lands in the cache.
            assertEquals(sampleJson, cache.stored)
        }

    @Test
    fun `config flow emits null then the loaded value`() =
        runTest {
            val service =
                ConfigService("admin.example.com", clientReturning(sampleJson), InMemoryConfigCache())

            service.config.test {
                assertNull(awaitItem())
                service.load()
                assertEquals("admin.example.com", awaitItem()?.controlDomain)
            }
        }

    @Test
    fun `load falls back to the cached config when the network fails`() =
        runTest {
            val failingClient = HttpClient(MockEngine { throw IOException("offline") })
            val service =
                ConfigService("admin.example.com", failingClient, InMemoryConfigCache(sampleJson))

            val config = service.load()

            assertEquals("admin.example.com", config.controlDomain)
            assertEquals(config, service.config.value)
        }

    @Test
    fun `load rethrows when the network fails and nothing is cached`() =
        runTest {
            val failingClient = HttpClient(MockEngine { throw IOException("offline") })
            val service = ConfigService("admin.example.com", failingClient, InMemoryConfigCache())

            val exception = runCatching { service.load() }.exceptionOrNull()

            assertTrue(exception is IOException)
            assertNull(service.config.value)
        }

    @Test
    fun `refresh surfaces an http error as ConfigException`() =
        runTest {
            val service =
                ConfigService(
                    "admin.example.com",
                    clientReturning("nope", HttpStatusCode.ServiceUnavailable),
                    InMemoryConfigCache(),
                )

            val exception = runCatching { service.refresh() }.exceptionOrNull()

            assertTrue(exception is ConfigException)
            assertTrue(exception!!.message!!.contains("503"))
        }

    @Test
    fun `a pasted url with scheme and trailing slash still fetches config json over https`() =
        runTest {
            var requestedUrl: String? = null
            val client =
                HttpClient(
                    MockEngine { request ->
                        requestedUrl = request.url.toString()
                        respond(
                            content = sampleJson,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    },
                )

            ConfigService(" http://admin.example.com/ ", client, InMemoryConfigCache()).refresh()

            assertEquals("https://admin.example.com/config.json", requestedUrl)
        }

    @Test
    fun `an undecodable cache entry is ignored and the network result wins`() =
        runTest {
            val cache = InMemoryConfigCache("{not json")
            val service = ConfigService("admin.example.com", clientReturning(sampleJson), cache)

            val config = service.load()

            assertEquals("admin.example.com", config.controlDomain)
            assertEquals(sampleJson, cache.stored)
        }
}
