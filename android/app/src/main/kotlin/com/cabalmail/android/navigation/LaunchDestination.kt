package com.cabalmail.android.navigation

import android.net.Uri
import com.cabalmail.android.ui.feeds.FeedRoutes
import com.cabalmail.kit.models.NavState
import com.cabalmail.kit.models.RssItem
import com.cabalmail.kit.models.RssItemScope

/** One navigation the launch restore performs, in order. */
data class LaunchRoute(
    val route: String,
    /** Route to rewind to first, or null to stack on top. */
    val popUpTo: String?,
)

/**
 * Where a cold launch lands, from the resume session (resume-session plan,
 * Phase B): pure, so the ladder is unit-tested without a `NavController`.
 *
 * Mail: the session's folder (INBOX when none), and its message when the
 * caller confirmed the message is still reachable — the list route with
 * `?uid=` on wide windows, the list plus the pushed reader on phones, the
 * same shape `cursorNavigation` gives the cross-device cursor. A launch
 * that would otherwise have stayed on the folder hub (medium widths, no
 * saved folder) still does.
 *
 * Feeds: the Feeds destination, then the saved scope's item list when the
 * caller confirmed the scope still exists, carrying the saved item when it
 * is still in the store — preselected in the wide pane, pushed as the
 * reader on phones. A departed scope degrades to the feed tree, a pruned
 * item to its list.
 */
object LaunchDestination {
    /** The default mail landing when nothing is saved. */
    const val INBOX = "INBOX"

    fun mailRoutes(
        session: ResumeSession?,
        compactWidth: Boolean,
        launchIntoInbox: Boolean,
        messageReachable: Boolean,
        encode: (String) -> String = Uri::encode,
    ): List<LaunchRoute> {
        val folder = session?.folder?.takeIf { it.isNotEmpty() }
        if (folder == null && !launchIntoInbox) return emptyList()
        val target = folder ?: INBOX
        val uid = session?.uid?.takeIf { folder != null && messageReachable && session.hasMessage }
        val plan = cursorNavigation(encode(target), uid, compactWidth)
        return buildList {
            add(LaunchRoute(plan.listRoute, plan.popUpTo))
            plan.readerRoute?.let { add(LaunchRoute(it, null)) }
        }
    }

    /**
     * The feed-side routes to navigate after switching to the Feeds
     * destination. [scope] is the saved scope only when the caller verified
     * it still exists; [item] is the saved item only when it is still in
     * the store.
     */
    fun feedRoutes(
        scope: RssItemScope?,
        item: RssItem?,
        compactWidth: Boolean,
        encode: (String) -> String = Uri::encode,
    ): List<LaunchRoute> {
        if (scope == null) return emptyList()
        return buildList {
            add(LaunchRoute(FeedRoutes.items(scope, item.takeIf { !compactWidth }, encode), FeedRoutes.HUB))
            if (compactWidth && item != null) {
                add(LaunchRoute(FeedRoutes.item(item.feedId, item.sortKey, encode), null))
            }
        }
    }
}

/**
 * Whether the server cursor is worth a "pick up where you left off"
 * prompt: written by another install, newer than the last one this install
 * was shown (the persisted watermark), and not the place this install is
 * already at. This install's own cursor is never offered back to it — the
 * local session has already restored it.
 */
object ForeignCursorPolicy {
    fun shouldOffer(
        cursor: NavState,
        localClientId: String,
        offeredWatermark: Long,
        session: ResumeSession?,
    ): Boolean {
        val writer = cursor.clientId ?: return false
        if (writer.isEmpty() || writer == localClientId) return false
        val updatedAt = cursor.updatedAt ?: return false
        if (updatedAt <= offeredWatermark) return false
        if (cursor.folder.isNullOrEmpty()) return false
        return !samePlace(cursor, session)
    }

    /**
     * Same folder and — when either side names a message — the same
     * message, by Message-ID when both carry one, else by UID. A feeds
     * session restores the feed reader, so no mail cursor matches it.
     */
    fun samePlace(
        cursor: NavState,
        session: ResumeSession?,
    ): Boolean {
        if (session == null || session.section != ResumeSection.MAIL) return false
        if (session.folder == null || cursor.folder != session.folder) return false
        val cursorHasMessage = cursor.uid != null || cursor.messageId != null
        if (!cursorHasMessage && !session.hasMessage) return true
        if (!cursorHasMessage || !session.hasMessage) return false
        val wanted = cursor.messageId
        val have = session.messageId
        if (wanted != null && have != null) return wanted == have
        return cursor.uid != null && cursor.uid == session.uid
    }
}
