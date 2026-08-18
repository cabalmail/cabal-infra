package com.cabalmail.android

import com.cabalmail.kit.CabalmailException
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import kotlin.coroutines.cancellation.CancellationException

/**
 * User-facing text for a failure (plan §7.5): the kit's structured
 * exceptions map to specific wording, transport failures to an offline /
 * network line, and anything else to the caller's fallback rather than a
 * raw exception message.
 */
fun userMessage(
    error: Throwable,
    fallback: String,
): String =
    when (error) {
        is CabalmailException.AuthExpired -> "Your session expired — sign in again"
        is CabalmailException.NotSignedIn -> "Sign in to continue"
        is CabalmailException.InvalidCredentials -> "Invalid username or password"
        is CabalmailException.Maintenance ->
            error.retryAfterSeconds?.let { "Mail is briefly in maintenance; try again in about ${it}s" }
                ?: "Mail is briefly in maintenance; try again shortly"
        is CabalmailException.ApiError ->
            when (error.httpStatus) {
                in 500..599 -> "$fallback (server error)"
                429 -> "Slow down — too many requests"
                else -> error.message?.takeIf { it.isNotBlank() } ?: fallback
            }
        is CabalmailException.DecodingError, is CabalmailException.ProtocolError -> "$fallback (unexpected reply)"
        is CabalmailException.ServerError -> error.message ?: fallback
        is UnknownHostException -> "You're offline — showing what's cached"
        is SocketTimeoutException -> "The server took too long to respond"
        is IOException -> "Network error — check your connection"
        is CancellationException -> fallback
        else -> error.message?.takeIf { it.isNotBlank() } ?: fallback
    }

/** True for failures a retry after reconnecting can plausibly fix. */
fun isTransient(error: Throwable): Boolean =
    error is IOException || error is CabalmailException.Maintenance ||
        (error is CabalmailException.ApiError && error.httpStatus in 500..599)
