package com.cabalmail.android.ui.feeds

import com.cabalmail.kit.models.RssFeedSummary
import com.cabalmail.kit.models.RssFolder
import com.cabalmail.kit.models.RssFolderUpdate
import com.cabalmail.kit.models.RssOpenMode
import com.cabalmail.kit.models.RssOpmlImportResult
import com.cabalmail.kit.models.RssOrderingMode
import com.cabalmail.kit.models.RssRemoteContentMode
import com.cabalmail.kit.models.RssStyling
import com.cabalmail.kit.models.RssSubscription
import com.cabalmail.kit.models.RssSubscriptionUpdate
import java.net.URI

// The pure rules behind the feed management sheets, mirroring the Apple
// `FeedForms.swift` so both clients validate, diff, and word things the
// same way; unit-tested without Compose.

/** One row of a folder picker: the folder, and how deep it sits. */
data class FeedFolderChoice(
    val folder: RssFolder,
    val depth: Int,
)

object FeedFormRules {
    /**
     * The address a subscribe form sends: trimmed, `https://` prefixed when
     * no scheme was typed (an explicit `http://` is left alone; the server
     * decides whether it can upgrade, with its own message), and it must
     * parse with a dotted host. Null when there is nothing to send.
     */
    fun normalizedFeedUrl(input: String): String? {
        val trimmed = input.trim()
        if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null
        val lower = trimmed.lowercase()
        val candidate = if (lower.startsWith("http://") || lower.startsWith("https://")) trimmed else "https://$trimmed"
        val host = runCatching { URI(candidate).host }.getOrNull() ?: return null
        if (!host.contains('.')) return null
        return candidate
    }

    /**
     * The folders a picker offers, depth first, siblings by display order
     * then name; [excluding] drops that folder and its whole subtree (a
     * folder cannot move under itself). The root is not a row; pickers add
     * their own "None (top level)" entry.
     */
    fun folderChoices(
        folders: List<RssFolder>,
        excluding: String? = null,
    ): List<FeedFolderChoice> {
        val byParent = folders.groupBy { it.parentFolderId }
        val out = ArrayList<FeedFolderChoice>()

        fun visit(
            parent: String,
            depth: Int,
        ) {
            byParent[parent]
                .orEmpty()
                .sortedWith(compareBy({ it.displayOrder }, { it.name.lowercase() }))
                .forEach { folder ->
                    if (folder.folderId == excluding) return@forEach
                    out += FeedFolderChoice(folder, depth)
                    visit(folder.folderId, depth + 1)
                }
        }
        visit("", 0)
        return out
    }

    /** Only the settings that differ from the row; null when nothing changed, so Save stays disabled. */
    fun settingsUpdate(
        subscription: RssSubscription,
        customTitle: String,
        folderId: String,
        orderingMode: RssOrderingMode,
        defaultOpenMode: RssOpenMode,
        defaultStyling: RssStyling,
        defaultRemoteContent: RssRemoteContentMode,
    ): RssSubscriptionUpdate? {
        val title = customTitle.trim()
        val update =
            RssSubscriptionUpdate(
                customTitle = title.takeIf { it != subscription.customTitle },
                folderId = folderId.takeIf { it != subscription.folderId },
                orderingMode = orderingMode.takeIf { it != subscription.orderingMode },
                defaultOpenMode = defaultOpenMode.takeIf { it != subscription.defaultOpenMode },
                defaultStyling = defaultStyling.takeIf { it != subscription.defaultStyling },
                defaultRemoteContent = defaultRemoteContent.takeIf { it != subscription.defaultRemoteContent },
            )
        return update.takeUnless { it.isEmpty }
    }

    /** A rename or move of an existing folder; null when nothing changed or the name is blank. */
    fun folderUpdate(
        editing: RssFolder,
        name: String,
        parentId: String,
    ): RssFolderUpdate? {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return null
        val update =
            RssFolderUpdate(
                name = trimmed.takeIf { it != editing.name },
                parentFolderId = parentId.takeIf { it != editing.parentFolderId },
            )
        return update.takeUnless { it.isEmpty }
    }
}

/** The subscription settings sheet's Feed section, in the Apple wording. */
object FeedHealthText {
    fun status(feed: RssFeedSummary): String =
        when {
            feed.deadLettered -> "Stopped: the fetcher gave up on this feed"
            feed.consecutiveFailureCount > 0 ->
                "Failing (${feed.consecutiveFailureCount} in a row, last status ${feed.lastStatusCode})"
            feed.lastFetchedAt.isEmpty() -> "Not fetched yet"
            else -> "OK"
        }

    fun lastFetched(feed: RssFeedSummary): String =
        if (feed.lastFetchedAt.isEmpty()) {
            "Never"
        } else {
            FeedItemDate
                .relative(
                    feed.lastFetchedAt,
                ).ifEmpty { feed.lastFetchedAt }
        }

    fun cadence(feed: RssFeedSummary): String =
        when {
            feed.cadenceMinutes <= 0 -> "Not scheduled yet"
            feed.cadenceMinutes < 60 -> "About every ${feed.cadenceMinutes} minutes"
            feed.cadenceMinutes == 60 -> "About every hour"
            else -> "About every ${feed.cadenceMinutes / 60} hours"
        }
}

/** The OPML import result as one message, the Apple `FeedOpmlSummary` wording. */
object FeedOpmlSummary {
    fun text(result: RssOpmlImportResult): String {
        val parts = ArrayList<String>()
        parts += "${result.created} new ${if (result.created == 1) "feed" else "feeds"}"
        if (result.existing > 0) {
            parts += "${result.existing} ${if (result.existing == 1) "feed" else "feeds"} already subscribed"
        }
        if (result.foldersCreated > 0) {
            parts += "${result.foldersCreated} ${if (result.foldersCreated == 1) "folder" else "folders"} created"
        }
        val summary = parts.joinToString(", ") + "."
        if (result.failed.isEmpty()) return summary
        val count = result.failed.size
        val shown = result.failed.take(5)
        val more = if (count > 5) " (and ${count - 5} more)" else ""
        val lines = shown.joinToString("\n") { "${it.url}: ${it.message.ifEmpty { it.code }}" }
        return "$summary\n\n$count ${if (count == 1) "entry" else "entries"} could not be added$more:\n$lines"
    }
}
