package com.cabalmail.kit.models

import com.cabalmail.kit.settings.WireEnum
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Wire models for the RSS reader API (`docs/rss.md`), transcribed field for
// field from the deployed contract; the Apple `CabalmailKit` `Rss.swift` is
// the reference consumer. Every field has a default so a missing key
// decodes, and enums decode leniently through [RssWire.json]: an unknown
// value (a mode a newer server added) reads as the field's default rather
// than failing the whole response.

/** The JSON configuration every RSS payload is decoded with. */
object RssWire {
    val json =
        Json {
            ignoreUnknownKeys = true
            coerceInputValues = true
        }
}

@Serializable
enum class RssOrderingMode(
    override val wire: String,
) : WireEnum {
    @SerialName("newest_first")
    NEWEST_FIRST("newest_first"),

    @SerialName("oldest_first")
    OLDEST_FIRST("oldest_first"),

    @SerialName("newest_day_oldest_within")
    NEWEST_DAY_OLDEST_WITHIN("newest_day_oldest_within"),

    @SerialName("oldest_day_newest_within")
    OLDEST_DAY_NEWEST_WITHIN("oldest_day_newest_within"),
}

/** What opens first for an item: the feed's own content or the article. */
@Serializable
enum class RssOpenMode(
    override val wire: String,
) : WireEnum {
    @SerialName("summary")
    SUMMARY("summary"),

    @SerialName("article")
    ARTICLE("article"),
}

@Serializable
enum class RssStyling(
    override val wire: String,
) : WireEnum {
    @SerialName("reader")
    READER("reader"),

    @SerialName("native")
    NATIVE("native"),
}

/** `INHERIT` defers to the app's remote-content preference; the others override it for one feed. */
@Serializable
enum class RssRemoteContentMode(
    override val wire: String,
) : WireEnum {
    @SerialName("inherit")
    INHERIT("inherit"),

    @SerialName("show")
    SHOW("show"),

    @SerialName("hide")
    HIDE("hide"),
}

/** The item list's filter pill; feeds and feed folders open on [UNREAD] until the user picks another. */
@Serializable
enum class RssItemFilter(
    override val wire: String,
) : WireEnum {
    @SerialName("all")
    ALL("all"),

    @SerialName("unread")
    UNREAD("unread"),

    @SerialName("favorite")
    FAVORITE("favorite"),

    ;

    companion object {
        val DEFAULT_FOR_FEEDS = UNREAD
    }
}

/** The server-side sort of a merged listing (request only). */
enum class RssItemOrder(
    val wire: String,
) {
    NEWEST("newest"),
    OLDEST("oldest"),
}

/**
 * What an item list covers. The [token] form (`all` | `sub:<id>` |
 * `folder:<id>`) is the identity the session record and the cross-device
 * cursor store, the same strings the Apple client's `RssItemScope` uses, so
 * a position hands between platforms without translation.
 */
sealed class RssItemScope {
    data object All : RssItemScope()

    data class Folder(
        val folderId: String,
    ) : RssItemScope()

    data class Subscription(
        val subscriptionId: String,
    ) : RssItemScope()

    val token: String
        get() =
            when (this) {
                All -> "all"
                is Folder -> "folder:$folderId"
                is Subscription -> "sub:$subscriptionId"
            }

    companion object {
        /** Null for an unknown prefix or an empty id. */
        fun fromToken(token: String): RssItemScope? {
            if (token == "all") return All
            val separator = token.indexOf(':')
            if (separator <= 0) return null
            val id = token.substring(separator + 1)
            if (id.isEmpty()) return null
            return when (token.substring(0, separator)) {
                "sub" -> Subscription(id)
                "folder" -> Folder(id)
                else -> null
            }
        }
    }
}

/** The `feed` summary on every subscription; the health fields drive the sidebar badge. */
@Serializable
data class RssFeedSummary(
    @SerialName("feed_id") val feedId: String,
    @SerialName("canonical_url") val canonicalUrl: String = "",
    @SerialName("feed_type") val feedType: String = "",
    val title: String = "",
    val description: String = "",
    @SerialName("site_url") val siteUrl: String = "",
    @SerialName("item_count") val itemCount: Int = 0,
    @SerialName("last_fetched_at") val lastFetchedAt: String = "",
    @SerialName("last_attempt_at") val lastAttemptAt: String = "",
    @SerialName("last_status_code") val lastStatusCode: Int = 0,
    @SerialName("last_error") val lastError: String = "",
    @SerialName("consecutive_failure_count") val consecutiveFailureCount: Int = 0,
    @SerialName("cadence_minutes") val cadenceMinutes: Int = 0,
    @SerialName("next_fetch_at") val nextFetchAt: String = "",
    @SerialName("dead_lettered") val deadLettered: Boolean = false,
)

@Serializable
data class RssSubscription(
    @SerialName("subscription_id") val subscriptionId: String,
    @SerialName("feed_id") val feedId: String,
    /** Empty = root. */
    @SerialName("folder_id") val folderId: String = "",
    @SerialName("custom_title") val customTitle: String = "",
    @SerialName("ordering_mode") val orderingMode: RssOrderingMode = RssOrderingMode.NEWEST_FIRST,
    @SerialName("default_open_mode") val defaultOpenMode: RssOpenMode = RssOpenMode.SUMMARY,
    @SerialName("default_styling") val defaultStyling: RssStyling = RssStyling.READER,
    @SerialName("default_remote_content") val defaultRemoteContent: RssRemoteContentMode =
        RssRemoteContentMode.INHERIT,
    @SerialName("default_filter") val defaultFilter: RssItemFilter = RssItemFilter.DEFAULT_FOR_FEEDS,
    @SerialName("notifications_enabled") val notificationsEnabled: Boolean = false,
    @SerialName("credentials_scheme") val credentialsScheme: String = "",
    @SerialName("read_watermark") val readWatermark: String = "",
    /** The per-subscription identifier the isolated web-view profile is keyed on. */
    @SerialName("data_store_uuid") val dataStoreUuid: String = "",
    @SerialName("created_at") val createdAt: String = "",
    val feed: RssFeedSummary? = null,
) {
    /** The custom title, else the feed's, else its address, else the id. */
    val displayTitle: String
        get() =
            customTitle.ifEmpty {
                feed?.title?.ifEmpty { null } ?: feed?.canonicalUrl?.ifEmpty { null } ?: feedId
            }

    /** The row after [update], the way the server will report it. */
    fun applying(update: RssSubscriptionUpdate): RssSubscription =
        copy(
            customTitle = update.customTitle ?: customTitle,
            folderId = update.folderId ?: folderId,
            orderingMode = update.orderingMode ?: orderingMode,
            defaultOpenMode = update.defaultOpenMode ?: defaultOpenMode,
            defaultStyling = update.defaultStyling ?: defaultStyling,
            defaultRemoteContent = update.defaultRemoteContent ?: defaultRemoteContent,
            defaultFilter = update.defaultFilter ?: defaultFilter,
            notificationsEnabled = update.notificationsEnabled ?: notificationsEnabled,
        )
}

@Serializable
data class RssFolder(
    @SerialName("folder_id") val folderId: String,
    /** Empty = root. */
    @SerialName("parent_folder_id") val parentFolderId: String = "",
    val name: String = "",
    @SerialName("display_order") val displayOrder: Int = 0,
    @SerialName("default_filter") val defaultFilter: RssItemFilter = RssItemFilter.DEFAULT_FOR_FEEDS,
) {
    fun applying(update: RssFolderUpdate): RssFolder =
        copy(
            name = update.name ?: name,
            parentFolderId = update.parentFolderId ?: parentFolderId,
            displayOrder = update.displayOrder ?: displayOrder,
            defaultFilter = update.defaultFilter ?: defaultFilter,
        )
}

/** `/rss_list_subscriptions`. */
@Serializable
data class RssCatalog(
    val folders: List<RssFolder> = emptyList(),
    val subscriptions: List<RssSubscription> = emptyList(),
)

@Serializable
data class RssItem(
    @SerialName("feed_id") val feedId: String,
    /** The item's key; opaque, passed back as given. */
    @SerialName("sort_key") val sortKey: String,
    @SerialName("subscription_id") val subscriptionId: String = "",
    @SerialName("item_id") val itemId: String = "",
    val guid: String = "",
    val title: String = "",
    val author: String = "",
    val url: String = "",
    @SerialName("published_at") val publishedAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
    @SerialName("fetched_at") val fetchedAt: String = "",
    /** The since-sync cursor value. */
    @SerialName("fetched_key") val fetchedKey: String = "",
    @SerialName("summary_html") val summaryHtml: String = "",
    @SerialName("content_html") val contentHtml: String = "",
    @SerialName("is_read") val isRead: Boolean = false,
    /** Whether [isRead] is the user's own mark rather than the watermark rule. */
    @SerialName("is_read_explicit") val isReadExplicit: Boolean = false,
    @SerialName("is_favorite") val isFavorite: Boolean = false,
) {
    /** Stable across feeds; `item_id` alone is not unique. */
    val id: String
        get() = "$feedId#$sortKey"

    val bodyHtml: String
        get() = contentHtml.ifEmpty { summaryHtml }
}

/** One row of the state-sync form of `/rss_list_items`. */
@Serializable
data class RssItemState(
    @SerialName("feed_id") val feedId: String,
    @SerialName("sort_key") val sortKey: String,
    @SerialName("item_id") val itemId: String = "",
    @SerialName("is_read") val isRead: Boolean = false,
    @SerialName("is_read_explicit") val isReadExplicit: Boolean = false,
    @SerialName("is_favorite") val isFavorite: Boolean = false,
    @SerialName("updated_at") val updatedAt: String = "",
)

/** A merged listing page; a null [nextCursor] means the server has no more. */
@Serializable
data class RssItemsPage(
    val items: List<RssItem> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
)

/** A since-sync page (ingest-time cursor). */
@Serializable
data class RssSyncPage(
    val items: List<RssItem> = emptyList(),
    @SerialName("next_since") val nextSince: String = "",
    @SerialName("has_more") val hasMore: Boolean = false,
)

/** A state-sync page. */
@Serializable
data class RssStateSyncPage(
    val states: List<RssItemState> = emptyList(),
    @SerialName("next_state_since") val nextSince: String = "",
    @SerialName("has_more") val hasMore: Boolean = false,
)

@Serializable
data class RssSubscribeResult(
    val subscription: RssSubscription,
    /** True when the caller already followed this feed. */
    val existing: Boolean = false,
)

@Serializable
data class RssUnsubscribeResult(
    @SerialName("subscription_id") val subscriptionId: String = "",
    @SerialName("feed_id") val feedId: String = "",
    @SerialName("feed_purged") val feedPurged: Boolean = false,
)

/** The optional fields of `/rss_update_subscription`; null means "leave alone". */
data class RssSubscriptionUpdate(
    val customTitle: String? = null,
    /** Empty moves the subscription to the root. */
    val folderId: String? = null,
    val orderingMode: RssOrderingMode? = null,
    val defaultOpenMode: RssOpenMode? = null,
    val defaultStyling: RssStyling? = null,
    val defaultRemoteContent: RssRemoteContentMode? = null,
    val defaultFilter: RssItemFilter? = null,
    val notificationsEnabled: Boolean? = null,
) {
    val isEmpty: Boolean
        get() =
            listOf(
                customTitle,
                folderId,
                orderingMode,
                defaultOpenMode,
                defaultStyling,
                defaultRemoteContent,
                defaultFilter,
                notificationsEnabled,
            ).all { it == null }
}

/** The optional fields of `/rss_update_folder`; null means "leave alone". */
data class RssFolderUpdate(
    val name: String? = null,
    /** Empty moves the folder to the root. */
    val parentFolderId: String? = null,
    val displayOrder: Int? = null,
    val defaultFilter: RssItemFilter? = null,
) {
    val isEmpty: Boolean
        get() = name == null && parentFolderId == null && displayOrder == null && defaultFilter == null
}

@Serializable
data class RssFolderDeleteResult(
    @SerialName("folder_id") val folderId: String = "",
    @SerialName("moved_subscriptions") val movedSubscriptions: Int = 0,
    @SerialName("moved_folders") val movedFolders: Int = 0,
    @SerialName("parent_folder_id") val parentFolderId: String = "",
)

/** One entry of `/rss_set_item_state`; a null flag is not sent. */
data class RssItemStateChange(
    val feedId: String,
    val sortKey: String,
    val isRead: Boolean? = null,
    val isFavorite: Boolean? = null,
)

@Serializable
data class RssMarkAllReadResult(
    val subscriptions: Int = 0,
    val flipped: Int = 0,
    @SerialName("read_watermark") val readWatermark: String = "",
)

@Serializable
data class RssOpmlImportFailure(
    val url: String = "",
    val code: String = "",
    @SerialName("Error") val message: String = "",
)

@Serializable
data class RssOpmlImportResult(
    val created: Int = 0,
    val existing: Int = 0,
    @SerialName("folders_created") val foldersCreated: Int = 0,
    val failed: List<RssOpmlImportFailure> = emptyList(),
)

@Serializable
data class RssOpmlExport(
    val opml: String = "",
    val filename: String = "",
)
