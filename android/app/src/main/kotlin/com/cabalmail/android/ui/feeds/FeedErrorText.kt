package com.cabalmail.android.ui.feeds

import com.cabalmail.android.userMessage
import com.cabalmail.kit.CabalmailException

/**
 * The RSS API's stable error codes as sentences (the Apple `FeedErrorText`
 * table, verbatim). Hardcoded English like [userMessage], which this falls
 * back to for anything without a known code.
 */
internal fun feedUserMessage(
    error: Throwable,
    fallback: String,
): String {
    val code = (error as? CabalmailException.ApiError)?.code
    return when (code) {
        "invalid_url" -> "That doesn't look like a feed address."
        "not_https" -> "This feed isn't available over a secure connection, so Cabalmail can't fetch it."
        "unreachable" -> "Cabalmail couldn't reach that address."
        "not_a_feed" -> "That address didn't return a feed, and the page doesn't advertise one."
        "needs_credentials" -> "The publisher requires a login for this feed. Private feeds arrive in a later release."
        "feed_gone" -> "The publisher says that feed is gone."
        "publisher_error" -> "The publisher returned an error. Try again later."
        "unknown_folder" -> "That folder no longer exists."
        "cyclic_folder" -> "A folder can't be moved inside itself."
        "nothing_to_update" -> "Nothing to change."
        "invalid_opml" -> "That file isn't an OPML outline."
        null -> userMessage(error, fallback)
        else -> error.message?.takeIf { it.isNotBlank() } ?: "Something went wrong ($code)."
    }
}
