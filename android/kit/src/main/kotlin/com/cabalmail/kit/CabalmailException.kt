package com.cabalmail.kit

/**
 * Error vocabulary shared across kit — the Kotlin analog of the Apple kit's
 * `CabalmailError`. UI layers map these to user-facing strings; nothing in
 * kit renders text to users.
 */
sealed class CabalmailException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    class NotSignedIn : CabalmailException("Not signed in")

    class InvalidCredentials : CabalmailException("Invalid username or password")

    class AuthExpired : CabalmailException("Session expired; sign in again")

    class ServerError(
        val code: String,
        message: String,
    ) : CabalmailException(message.ifEmpty { code })

    class ProtocolError(
        message: String,
    ) : CabalmailException(message)

    /** Non-2xx from the Lambda API, carrying the server's message. */
    class ApiError(
        val httpStatus: Int,
        message: String,
    ) : CabalmailException(message)

    /**
     * The mail plane is in scheduled maintenance (HTTP 503 with
     * `status: maintenance`) — retryable, distinct from a generic 5xx.
     */
    class Maintenance(
        val retryAfterSeconds: Int?,
        message: String,
    ) : CabalmailException(message)

    class DecodingError(
        message: String,
        cause: Throwable? = null,
    ) : CabalmailException(message, cause)

    /**
     * A `/set_rules` write lost the optimistic-concurrency race (HTTP 409):
     * another device saved first. Reload via `/get_rules` (which reads
     * consistently, so the winning write is guaranteed visible) and reapply.
     */
    class RuleSetConflict : CabalmailException("Rules changed on another device; reload.")
}
