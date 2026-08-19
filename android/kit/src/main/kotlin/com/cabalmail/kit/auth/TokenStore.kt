package com.cabalmail.kit.auth

/**
 * Secure persistence seam for the auth session, so [CognitoAuthService] can
 * be unit-tested with an in-memory fake. The production implementation is
 * [KeystoreTokenStore].
 *
 * Unlike the Apple kit's `SecureStore`, no password is ever persisted: the
 * Android client is API-backed only (no direct IMAP/SMTP login), so the
 * username is kept for display and the password is deliberately dropped
 * after sign-in.
 */
interface TokenStore {
    fun readTokens(): AuthTokens?

    fun writeTokens(tokens: AuthTokens)

    /** The signed-in Cognito username, or null when signed out. */
    fun readUsername(): String?

    fun writeUsername(username: String)

    /** Removes everything; the signed-out state. */
    fun clear()
}
