package com.cabalmail.kit.settings

import com.cabalmail.kit.api.ApiClient
import com.cabalmail.kit.auth.AuthService
import com.cabalmail.kit.auth.AuthTokens
import com.cabalmail.kit.auth.CodeDelivery
import com.cabalmail.kit.auth.RecoveryContacts
import com.cabalmail.kit.auth.SignInResult
import com.cabalmail.kit.auth.SignUpResult
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.IOException

/**
 * The server half of the settings sync, behind a real [ApiClient]: one
 * account's row, doing what `get_preferences` and `set_preferences` do with
 * it (`docs/settings-sync.md`). The Kotlin sibling of the Apple kit's
 * `FakeSettingsServer`.
 *
 * - `GET get_preferences` answers the flat keys, the `app` map and the
 *   row's `version`, a count of the writes it has taken.
 * - `PUT set_preferences` merges what it is sent, per key, and counts the
 *   version up by one. A request that names the version it was built on
 *   (`expectedVersion`) is written only if the row is still at it;
 *   otherwise nothing is written and the answer is a 409 holding the row.
 *   A request that names none is always written. A flag with an empty
 *   name refuses the whole request, as the server's own check does.
 *
 * Either endpoint can be made to fail as an unreachable server does
 * ([failing]); [refuseNext] makes the next write a 400; [predatesVersion]
 * makes this a server that neither answers nor checks a version;
 * [anotherDeviceWrites] is a second device's write. Every request is in
 * [calls], and every write's body in [writes].
 */
class FakeSettingsServer {
    /** The row's flat keys, as `get_preferences` answers them. */
    val flat = mutableMapOf("theme" to "light", "accent" to "forest", "density" to "compact", "name" to "")

    /** The row's `app` map. */
    val app = mutableMapOf<String, String>()

    /** How many writes the row has taken. */
    var version = 0

    /** Paths (`get_preferences`, `set_preferences`) that fail as an unreachable server does. */
    val failing = mutableSetOf<String>()

    /** Makes the next write a 400. */
    var refuseNext = false

    /** A server from before the version: it answers none and checks none. */
    var predatesVersion = false

    /** Another device writes just ahead of every write from now on. */
    var keepsMovingOn = false

    /** Each request and how it went: `get_preferences ok`, `set_preferences stale`. */
    val calls = mutableListOf<String>()

    /** The body of each write that arrived, however it was answered. */
    val writes = mutableListOf<JsonObject>()

    /** Writes naming a version, in order; null for a write that named none. */
    val writeVersions: List<Int?> get() = writes.map { it["expectedVersion"]?.jsonPrimitive?.int }

    /** A write from another device: merged per key and counted, as any write is. */
    fun anotherDeviceWrites(
        app: Map<String, String> = emptyMap(),
        flat: Map<String, String> = emptyMap(),
    ) {
        this.app += app
        this.flat += flat
        version += 1
    }

    private fun row() =
        buildJsonObject {
            flat.forEach { (key, value) -> put(key, value) }
            putJsonObject("app") { app.forEach { (key, value) -> put(key, value) } }
            if (!predatesVersion) put("version", version)
        }

    private fun takes(sent: Map<String, String>): Boolean {
        val palette = sent[PreferencesWire.AppKey.FLAG_PALETTE]?.let(FlagPalette::decode) ?: return true
        return palette.none { it.label.isEmpty() }
    }

    private fun write(body: JsonObject): Pair<HttpStatusCode, String> {
        writes += body
        val sentApp = body["app"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content }.orEmpty()
        val sentFlat = flat.keys.mapNotNull { key -> body[key]?.jsonPrimitive?.content?.let { key to it } }.toMap()
        val refusing = refuseNext.also { refuseNext = false }
        if (refusing || !takes(sentApp)) {
            calls += "set_preferences refused"
            return HttpStatusCode.BadRequest to """{"Error": "Invalid value for app."}"""
        }
        if (keepsMovingOn) version += 1
        val expected = body["expectedVersion"]?.jsonPrimitive?.int
        if (!predatesVersion && expected != null && expected != version) {
            calls += "set_preferences stale"
            val answer = JsonObject(row() + buildJsonObject { put("Error", "Preferences changed on another device.") })
            return HttpStatusCode.Conflict to answer.toString()
        }
        app += sentApp
        flat += sentFlat
        version += 1
        calls += "set_preferences ok"
        val answer =
            buildJsonObject {
                putJsonObject("app") { sentApp.forEach { (key, value) -> put(key, value) } }
                if (!predatesVersion) put("version", version)
            }
        return HttpStatusCode.OK to answer.toString()
    }

    /** A client of this server. */
    val api: ApiClient =
        ApiClient(
            baseUrl = "https://api.example.com/v1",
            host = "imap.example.com",
            authService = NoAuth,
            httpClient =
                HttpClient(
                    MockEngine { request ->
                        val path = request.url.encodedPath.substringAfterLast('/')
                        if (path in failing) {
                            calls += "$path offline"
                            throw IOException("unreachable")
                        }
                        val (status, body) =
                            when (path) {
                                "get_preferences" -> {
                                    calls += "get_preferences ok"
                                    HttpStatusCode.OK to row().toString()
                                }
                                "set_preferences" ->
                                    write(Json.parseToJsonElement((request.body as TextContent).text).jsonObject)
                                else -> error("FakeSettingsServer: unexpected request to $path")
                            }
                        respond(body, status, headersOf(HttpHeaders.ContentType, "application/json"))
                    },
                ),
        )

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

        override suspend fun recoveryContacts() = RecoveryContacts(null, emailVerified = false, phoneVerified = false)

        override suspend fun setRecoveryEmail(address: String) = Unit

        override suspend fun sendRecoveryEmailCode() = Unit

        override suspend fun verifyRecoveryEmail(code: String) = Unit

        override suspend fun currentIdToken(): String = "t"

        override suspend fun forceRefreshedIdToken(): String = "t"

        override fun currentUsername(): String? = null

        override fun currentTokens(): AuthTokens? = null
    }
}
