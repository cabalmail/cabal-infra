package com.cabalmail.kit.auth

/** Which second factor Cognito is asking for mid-sign-in. */
enum class MfaMethod(
    val challengeName: String,
    /** Key inside `ChallengeResponses` that carries the user's code. */
    val responseCodeKey: String,
) {
    /** `SOFTWARE_TOKEN_MFA` — a TOTP code from an authenticator app. */
    TOTP("SOFTWARE_TOKEN_MFA", "SOFTWARE_TOKEN_MFA_CODE"),

    /** `SMS_MFA` — a code Cognito just texted to the verified phone. */
    SMS("SMS_MFA", "SMS_MFA_CODE"),
    ;

    companion object {
        fun fromChallengeName(name: String): MfaMethod? = entries.firstOrNull { it.challengeName == name }
    }
}

/**
 * Outcome of [AuthService.signIn]: either tokens are stored and the session
 * is live, or Cognito answered with an MFA challenge that
 * [AuthService.submitMfaCode] must complete before any token exists.
 */
sealed interface SignInResult {
    data object SignedIn : SignInResult

    data class MfaCodeRequired(
        val method: MfaMethod,
    ) : SignInResult
}

/**
 * Interface surfaced to the app layer and to `ApiClient`.
 *
 * Mirrors the Apple kit's `AuthService` protocol: a hand-rolled Cognito
 * `USER_PASSWORD_AUTH` JSON client rather than Amplify. The pool is
 * configured with `explicit_auth_flows = ["USER_PASSWORD_AUTH"]`
 * (`terraform/infra/modules/user_pool/main.tf`), so the cleartext-flow JSON
 * API is sufficient, proven by both existing native clients, and ~4 MB
 * lighter than Amplify after R8. (The plan's "Default: Amplify" predates the
 * erratum noting the Apple client never actually shipped Amplify.)
 */
interface AuthService {
    suspend fun signIn(
        username: String,
        password: String,
    ): SignInResult

    /**
     * Completes a sign-in that [signIn] answered with
     * [SignInResult.MfaCodeRequired]. A wrong code throws but leaves the
     * challenge session usable for a bounded number of retries.
     */
    suspend fun submitMfaCode(code: String)

    suspend fun signUp(
        username: String,
        password: String,
        email: String?,
        phone: String?,
    )

    suspend fun confirmSignUp(
        username: String,
        code: String,
    )

    suspend fun resendConfirmationCode(username: String)

    suspend fun forgotPassword(username: String)

    suspend fun confirmForgotPassword(
        username: String,
        code: String,
        newPassword: String,
    )

    suspend fun signOut()

    /** Fresh ID token for API requests; refreshes automatically when stale. */
    suspend fun currentIdToken(): String

    /**
     * Refreshes unconditionally and returns the new ID token — the 401-replay
     * path in `ApiClient`, where the server has rejected a token the client
     * still believed fresh.
     */
    suspend fun forceRefreshedIdToken(): String

    /** The signed-in username, or null when signed out. */
    fun currentUsername(): String?

    /** Tokens currently in the secure store, or null if signed out. */
    fun currentTokens(): AuthTokens?
}
