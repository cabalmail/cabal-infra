package com.cabalmail.kit.auth

import com.cabalmail.kit.CabalmailException
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Concrete Cognito IdP implementation of [AuthService] — a direct port of
 * the Apple kit's `CognitoAuthService` actor. All operations POST to
 * `https://cognito-idp.{region}.amazonaws.com/` with JSON bodies and an
 * `X-Amz-Target` header: the raw AWS REST API every Cognito SDK wraps.
 */
class CognitoAuthService(
    private val clientId: String,
    region: String,
    private val httpClient: HttpClient,
    private val tokenStore: TokenStore,
    private val clock: () -> Long = System::currentTimeMillis,
) : AuthService {
    private val endpoint = "https://cognito-idp.$region.amazonaws.com/"

    private val json = Json { ignoreUnknownKeys = true }

    // Serializes sign-in/refresh so concurrent API calls can't race a token
    // refresh — the coroutine analog of the Swift actor's isolation.
    private val mutex = Mutex()

    /**
     * Mid-sign-in MFA challenge state. Cognito hands back an opaque
     * `Session` that `RespondToAuthChallenge` must echo. Memory-only by
     * design: a relaunch mid-challenge restarts the sign-in.
     */
    private data class PendingChallenge(
        val method: MfaMethod,
        val session: String,
        val username: String,
    )

    private var pendingChallenge: PendingChallenge? = null

    override suspend fun signIn(
        username: String,
        password: String,
    ): SignInResult =
        mutex.withLock {
            pendingChallenge = null
            val response =
                call(
                    "InitiateAuth",
                    buildJsonObject {
                        put("AuthFlow", "USER_PASSWORD_AUTH")
                        put("ClientId", clientId)
                        putJsonObject("AuthParameters") {
                            put("USERNAME", username)
                            put("PASSWORD", password)
                        }
                    },
                )
            val challenge = response.stringOrNull("ChallengeName")
            if (challenge != null) {
                val method = MfaMethod.fromChallengeName(challenge)
                val session = response.stringOrNull("Session")
                if (method == null || session == null) {
                    // NEW_PASSWORD_REQUIRED, MFA_SETUP, ... — nothing the
                    // app flow can produce with the current pool config.
                    throw CabalmailException.ProtocolError("Unhandled challenge: $challenge")
                }
                pendingChallenge = PendingChallenge(method, session, username)
                return@withLock SignInResult.MfaCodeRequired(method)
            }
            complete(parseAuthResult(response), username)
            SignInResult.SignedIn
        }

    override suspend fun submitMfaCode(code: String) {
        mutex.withLock {
            val pending = pendingChallenge ?: throw CabalmailException.NotSignedIn()
            val response =
                call(
                    "RespondToAuthChallenge",
                    buildJsonObject {
                        put("ChallengeName", pending.method.challengeName)
                        put("ClientId", clientId)
                        put("Session", pending.session)
                        putJsonObject("ChallengeResponses") {
                            put("USERNAME", pending.username)
                            put(pending.method.responseCodeKey, code)
                        }
                    },
                )
            // A wrong code surfaces as CodeMismatchException from call();
            // Cognito keeps the challenge session valid for a bounded number
            // of retries, so pendingChallenge is kept until success.
            complete(parseAuthResult(response), pending.username)
            pendingChallenge = null
        }
    }

    override suspend fun signUp(
        username: String,
        password: String,
        email: String?,
        phone: String?,
    ) {
        call(
            "SignUp",
            buildJsonObject {
                put("ClientId", clientId)
                put("Username", username)
                put("Password", password)
                putJsonArray("UserAttributes") {
                    if (!email.isNullOrEmpty()) {
                        add(
                            buildJsonObject {
                                put("Name", "email")
                                put("Value", email)
                            },
                        )
                    }
                    if (!phone.isNullOrEmpty()) {
                        add(
                            buildJsonObject {
                                put("Name", "phone_number")
                                put("Value", phone)
                            },
                        )
                    }
                }
            },
        )
    }

    override suspend fun confirmSignUp(
        username: String,
        code: String,
    ) {
        call(
            "ConfirmSignUp",
            buildJsonObject {
                put("ClientId", clientId)
                put("Username", username)
                put("ConfirmationCode", code)
            },
        )
    }

    override suspend fun resendConfirmationCode(username: String) {
        call(
            "ResendConfirmationCode",
            buildJsonObject {
                put("ClientId", clientId)
                put("Username", username)
            },
        )
    }

    override suspend fun forgotPassword(username: String) {
        call(
            "ForgotPassword",
            buildJsonObject {
                put("ClientId", clientId)
                put("Username", username)
            },
        )
    }

    override suspend fun confirmForgotPassword(
        username: String,
        code: String,
        newPassword: String,
    ) {
        call(
            "ConfirmForgotPassword",
            buildJsonObject {
                put("ClientId", clientId)
                put("Username", username)
                put("ConfirmationCode", code)
                put("Password", newPassword)
            },
        )
    }

    override suspend fun signOut() {
        mutex.withLock {
            pendingChallenge = null
            tokenStore.clear()
        }
    }

    override suspend fun currentIdToken(): String =
        mutex.withLock {
            val tokens = tokenStore.readTokens() ?: throw CabalmailException.NotSignedIn()
            if (!tokens.isExpired(clock())) {
                return@withLock tokens.idToken
            }
            val refreshed = refresh(tokens)
            tokenStore.writeTokens(refreshed)
            refreshed.idToken
        }

    override suspend fun forceRefreshedIdToken(): String =
        mutex.withLock {
            val tokens = tokenStore.readTokens() ?: throw CabalmailException.NotSignedIn()
            val refreshed = refresh(tokens)
            tokenStore.writeTokens(refreshed)
            refreshed.idToken
        }

    override fun currentUsername(): String? = tokenStore.readUsername()

    override fun currentTokens(): AuthTokens? = tokenStore.readTokens()

    private fun complete(
        tokens: AuthTokens,
        username: String,
    ) {
        tokenStore.writeTokens(tokens)
        tokenStore.writeUsername(username)
    }

    private suspend fun refresh(tokens: AuthTokens): AuthTokens {
        val refreshToken = tokens.refreshToken ?: throw CabalmailException.AuthExpired()
        val response =
            call(
                "InitiateAuth",
                buildJsonObject {
                    put("AuthFlow", "REFRESH_TOKEN_AUTH")
                    put("ClientId", clientId)
                    putJsonObject("AuthParameters") {
                        put("REFRESH_TOKEN", refreshToken)
                    }
                },
                // A refresh Cognito refuses means the session is over, not
                // that a credential was mistyped — nobody typed anything here.
                notAuthorized = { CabalmailException.AuthExpired() },
            )
        // REFRESH_TOKEN_AUTH omits the refresh token from the response —
        // reuse the existing one so subsequent refreshes keep working.
        val refreshed = parseAuthResult(response)
        return if (refreshed.refreshToken == null) refreshed.copy(refreshToken = refreshToken) else refreshed
    }

    /**
     * @param notAuthorized what a `NotAuthorizedException` means for this call.
     *   Cognito answers it both to a sign-in with a bad password and to a
     *   refresh whose token has expired or been revoked, and only the caller
     *   knows which it asked for (#1288).
     */
    private suspend fun call(
        target: String,
        body: JsonObject,
        notAuthorized: () -> CabalmailException = { CabalmailException.InvalidCredentials() },
    ): JsonObject {
        val response =
            httpClient.post(endpoint) {
                header("X-Amz-Target", "AWSCognitoIdentityProviderService.$target")
                contentType(ContentType("application", "x-amz-json-1.1"))
                setBody(body.toString())
            }
        val text = response.bodyAsText()
        if (!response.status.isSuccess()) {
            val (code, message) = parseError(text)
            when (code) {
                "NotAuthorizedException" -> throw notAuthorized()
                // A pool trigger (require_admin_mfa, check_invite, ...)
                // rejected the call; the trigger's own message is the
                // user-facing part, not Cognito's wrapper around it.
                "UserLambdaValidationException" ->
                    throw CabalmailException.ServerError(code, stripLambdaTriggerWrapper(message))
                else -> throw CabalmailException.ServerError(code, message)
            }
        }
        return if (text.isBlank()) {
            JsonObject(emptyMap())
        } else {
            json.parseToJsonElement(text).jsonObject
        }
    }

    private fun parseError(text: String): Pair<String, String> {
        val obj =
            runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
                ?: return "Unknown" to text
        // Cognito errors come back either as {__type: "...", message: "..."}
        // or {code: "...", message: "..."} depending on the operation.
        val code =
            obj.stringOrNull("__type")?.substringAfterLast('#')
                ?: obj.stringOrNull("code")
                ?: "Unknown"
        val message = obj.stringOrNull("message") ?: obj.stringOrNull("Message") ?: ""
        return code to message
    }

    private fun parseAuthResult(response: JsonObject): AuthTokens {
        val result =
            response["AuthenticationResult"]?.jsonObject
                ?: run {
                    // MFA challenges are handled in signIn before this parser
                    // runs; a ChallengeName here (refresh flow) is genuinely
                    // unhandled.
                    response.stringOrNull("ChallengeName")?.let {
                        throw CabalmailException.ProtocolError("Unhandled challenge: $it")
                    }
                    throw CabalmailException.DecodingError("Missing AuthenticationResult")
                }
        val idToken =
            result.stringOrNull("IdToken")
                ?: throw CabalmailException.DecodingError("Missing tokens in AuthenticationResult")
        val accessToken =
            result.stringOrNull("AccessToken")
                ?: throw CabalmailException.DecodingError("Missing tokens in AuthenticationResult")
        val expiresIn = result["ExpiresIn"]?.jsonPrimitive?.intOrNull ?: 3600
        return AuthTokens(
            idToken = idToken,
            accessToken = accessToken,
            refreshToken = result.stringOrNull("RefreshToken"),
            tokenType = result.stringOrNull("TokenType") ?: "Bearer",
            expiresAtEpochMillis = clock() + expiresIn * 1000L,
        )
    }

    private fun JsonObject.stringOrNull(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

    companion object {
        /**
         * Cognito reports a Lambda-trigger rejection as
         * "<TriggerName> failed with error <trigger message>." — the wrapper
         * leaks the trigger's name and, when the trigger message has its own
         * terminal period, produces a doubled one. Returns just the
         * trigger's message. Internal-visible for direct unit coverage.
         */
        internal fun stripLambdaTriggerWrapper(message: String): String {
            var text = message
            val marker = " failed with error "
            val index = text.indexOf(marker)
            if (index > 0) {
                // Only strip when the lead-in is a bare trigger name; a
                // space means the phrase occurs mid-sentence in a real
                // message.
                val lead = text.substring(0, index)
                if (!lead.contains(' ')) {
                    text = text.substring(index + marker.length)
                }
            }
            while (text.endsWith("..")) {
                text = text.dropLast(1)
            }
            return text
        }
    }
}
