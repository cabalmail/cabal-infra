import Foundation

// Wire types for the RSS reader API (`docs/rss.md`), field for field. The
// server promises additive evolution: every field here is documented, new
// fields may appear and are ignored, and fields the server has always sent
// are decoded leniently (missing string -> "", missing number -> 0) so a
// build never fails to decode a row an older or newer Lambda produced.

// MARK: - Enums

/// Per-subscription item ordering. Stored server-side, applied client-side.
public enum RssOrderingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case newestFirst = "newest_first"
    case oldestFirst = "oldest_first"
    case newestDayOldestWithin = "newest_day_oldest_within"
    case oldestDayNewestWithin = "oldest_day_newest_within"

    public var id: String { rawValue }
}

/// What opening an item shows first: the in-feed body or the publisher's page.
public enum RssOpenMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case summary
    case article

    public var id: String { rawValue }
}

/// Reader-styled or the publisher's own styling, for the in-feed body and the article view.
public enum RssStyling: String, Codable, Sendable, CaseIterable, Identifiable {
    case reader
    case native

    public var id: String { rawValue }
}

/// `filter=` on `/rss_list_items`.
public enum RssItemFilter: String, Sendable, CaseIterable {
    case all
    case unread
    case favorite
}

/// `order=` on `/rss_list_items`.
public enum RssItemOrder: String, Sendable {
    case newest
    case oldest
}

/// Which items a listing or mark-all-read addresses.
public enum RssItemScope: Sendable, Hashable {
    case subscription(String)
    case folder(String)
    case all
}

// MARK: - Catalog

/// The `feed` summary riding on each subscription (title, site, health).
public struct RssFeedSummary: Sendable, Codable, Hashable {
    public var feedId: String
    public var canonicalUrl: String
    public var feedType: String
    public var title: String
    public var description: String
    public var siteUrl: String
    public var itemCount: Int
    public var lastFetchedAt: String
    public var lastAttemptAt: String
    public var lastStatusCode: Int
    public var lastError: String
    public var consecutiveFailureCount: Int
    public var cadenceMinutes: Int
    public var nextFetchAt: String
    public var deadLettered: Bool

    public init(
        feedId: String, canonicalUrl: String = "", feedType: String = "", title: String = "",
        description: String = "", siteUrl: String = "", itemCount: Int = 0,
        lastFetchedAt: String = "", lastAttemptAt: String = "", lastStatusCode: Int = 0,
        lastError: String = "", consecutiveFailureCount: Int = 0, cadenceMinutes: Int = 0,
        nextFetchAt: String = "", deadLettered: Bool = false
    ) {
        self.feedId = feedId
        self.canonicalUrl = canonicalUrl
        self.feedType = feedType
        self.title = title
        self.description = description
        self.siteUrl = siteUrl
        self.itemCount = itemCount
        self.lastFetchedAt = lastFetchedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastStatusCode = lastStatusCode
        self.lastError = lastError
        self.consecutiveFailureCount = consecutiveFailureCount
        self.cadenceMinutes = cadenceMinutes
        self.nextFetchAt = nextFetchAt
        self.deadLettered = deadLettered
    }

    private enum CodingKeys: String, CodingKey {
        case feedId = "feed_id", canonicalUrl = "canonical_url", feedType = "feed_type"
        case title, description, siteUrl = "site_url", itemCount = "item_count"
        case lastFetchedAt = "last_fetched_at", lastAttemptAt = "last_attempt_at"
        case lastStatusCode = "last_status_code", lastError = "last_error"
        case consecutiveFailureCount = "consecutive_failure_count"
        case cadenceMinutes = "cadence_minutes", nextFetchAt = "next_fetch_at"
        case deadLettered = "dead_lettered"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedId = try container.decode(String.self, forKey: .feedId)
        canonicalUrl = try container.decodeIfPresent(String.self, forKey: .canonicalUrl) ?? ""
        feedType = try container.decodeIfPresent(String.self, forKey: .feedType) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        siteUrl = try container.decodeIfPresent(String.self, forKey: .siteUrl) ?? ""
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        lastFetchedAt = try container.decodeIfPresent(String.self, forKey: .lastFetchedAt) ?? ""
        lastAttemptAt = try container.decodeIfPresent(String.self, forKey: .lastAttemptAt) ?? ""
        lastStatusCode = try container.decodeIfPresent(Int.self, forKey: .lastStatusCode) ?? 0
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        consecutiveFailureCount = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailureCount) ?? 0
        cadenceMinutes = try container.decodeIfPresent(Int.self, forKey: .cadenceMinutes) ?? 0
        nextFetchAt = try container.decodeIfPresent(String.self, forKey: .nextFetchAt) ?? ""
        deadLettered = try container.decodeIfPresent(Bool.self, forKey: .deadLettered) ?? false
    }
}

/// One of the caller's subscriptions. `folderId` is "" at the root.
public struct RssSubscription: Sendable, Codable, Hashable, Identifiable {
    public var subscriptionId: String
    public var feedId: String
    public var folderId: String
    public var customTitle: String
    public var orderingMode: RssOrderingMode
    public var defaultOpenMode: RssOpenMode
    public var defaultStyling: RssStyling
    public var notificationsEnabled: Bool
    public var credentialsScheme: String
    public var readWatermark: String
    public var dataStoreUuid: String
    public var createdAt: String
    public var feed: RssFeedSummary?

    public var id: String { subscriptionId }

    /// The title to show: the user's own when set, else the feed's, else its URL.
    public var displayTitle: String {
        if !customTitle.isEmpty { return customTitle }
        if let feed, !feed.title.isEmpty { return feed.title }
        return feed?.canonicalUrl ?? feedId
    }

    public init(
        subscriptionId: String, feedId: String, folderId: String = "", customTitle: String = "",
        orderingMode: RssOrderingMode = .newestFirst, defaultOpenMode: RssOpenMode = .summary,
        defaultStyling: RssStyling = .reader, notificationsEnabled: Bool = false,
        credentialsScheme: String = "", readWatermark: String = "", dataStoreUuid: String = "",
        createdAt: String = "", feed: RssFeedSummary? = nil
    ) {
        self.subscriptionId = subscriptionId
        self.feedId = feedId
        self.folderId = folderId
        self.customTitle = customTitle
        self.orderingMode = orderingMode
        self.defaultOpenMode = defaultOpenMode
        self.defaultStyling = defaultStyling
        self.notificationsEnabled = notificationsEnabled
        self.credentialsScheme = credentialsScheme
        self.readWatermark = readWatermark
        self.dataStoreUuid = dataStoreUuid
        self.createdAt = createdAt
        self.feed = feed
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id", feedId = "feed_id", folderId = "folder_id"
        case customTitle = "custom_title", orderingMode = "ordering_mode"
        case defaultOpenMode = "default_open_mode", defaultStyling = "default_styling"
        case notificationsEnabled = "notifications_enabled", credentialsScheme = "credentials_scheme"
        case readWatermark = "read_watermark", dataStoreUuid = "data_store_uuid"
        case createdAt = "created_at", feed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        feedId = try container.decode(String.self, forKey: .feedId)
        folderId = try container.decodeIfPresent(String.self, forKey: .folderId) ?? ""
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle) ?? ""
        // Unknown enum values from a newer server fall back to the default
        // rather than failing the whole catalog decode.
        let orderingRaw = try container.decodeIfPresent(String.self, forKey: .orderingMode) ?? ""
        orderingMode = RssOrderingMode(rawValue: orderingRaw) ?? .newestFirst
        let openRaw = try container.decodeIfPresent(String.self, forKey: .defaultOpenMode) ?? ""
        defaultOpenMode = RssOpenMode(rawValue: openRaw) ?? .summary
        let stylingRaw = try container.decodeIfPresent(String.self, forKey: .defaultStyling) ?? ""
        defaultStyling = RssStyling(rawValue: stylingRaw) ?? .reader
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        credentialsScheme = try container.decodeIfPresent(String.self, forKey: .credentialsScheme) ?? ""
        readWatermark = try container.decodeIfPresent(String.self, forKey: .readWatermark) ?? ""
        dataStoreUuid = try container.decodeIfPresent(String.self, forKey: .dataStoreUuid) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        feed = try container.decodeIfPresent(RssFeedSummary.self, forKey: .feed)
    }
}

/// A folder in the caller's hierarchy. `parentFolderId` is "" at the root.
public struct RssFolder: Sendable, Codable, Hashable, Identifiable {
    public var folderId: String
    public var parentFolderId: String
    public var name: String
    public var displayOrder: Int

    public var id: String { folderId }

    public init(folderId: String, parentFolderId: String = "", name: String, displayOrder: Int = 0) {
        self.folderId = folderId
        self.parentFolderId = parentFolderId
        self.name = name
        self.displayOrder = displayOrder
    }

    private enum CodingKeys: String, CodingKey {
        case folderId = "folder_id", parentFolderId = "parent_folder_id", name, displayOrder = "display_order"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folderId = try container.decode(String.self, forKey: .folderId)
        parentFolderId = try container.decodeIfPresent(String.self, forKey: .parentFolderId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder) ?? 0
    }
}

/// `/rss_list_subscriptions`.
public struct RssCatalog: Sendable, Codable, Hashable {
    public var folders: [RssFolder]
    public var subscriptions: [RssSubscription]

    public init(folders: [RssFolder], subscriptions: [RssSubscription]) {
        self.folders = folders
        self.subscriptions = subscriptions
    }
}

// MARK: - Items

/// One feed item with the caller's state folded in.
public struct RssItem: Sendable, Codable, Hashable, Identifiable {
    public var feedId: String
    public var subscriptionId: String
    public var itemId: String
    /// The item's server key; opaque, passed back on state changes.
    public var sortKey: String
    public var guid: String
    public var title: String
    public var author: String
    public var url: String
    public var publishedAt: String
    public var updatedAt: String
    public var fetchedAt: String
    /// The since-sync cursor value for this item.
    public var fetchedKey: String
    public var summaryHtml: String
    public var contentHtml: String
    public var isRead: Bool
    public var isFavorite: Bool

    /// Stable across feeds: two feeds could carry the same sort key.
    public var id: String { "\(feedId)#\(sortKey)" }

    /// The body to render: the full content when the feed delivered it,
    /// else the summary.
    public var bodyHtml: String { contentHtml.isEmpty ? summaryHtml : contentHtml }

    public init(
        feedId: String, subscriptionId: String = "", itemId: String, sortKey: String, guid: String = "",
        title: String = "", author: String = "", url: String = "", publishedAt: String = "",
        updatedAt: String = "", fetchedAt: String = "", fetchedKey: String = "",
        summaryHtml: String = "", contentHtml: String = "", isRead: Bool = false, isFavorite: Bool = false
    ) {
        self.feedId = feedId
        self.subscriptionId = subscriptionId
        self.itemId = itemId
        self.sortKey = sortKey
        self.guid = guid
        self.title = title
        self.author = author
        self.url = url
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
        self.fetchedKey = fetchedKey
        self.summaryHtml = summaryHtml
        self.contentHtml = contentHtml
        self.isRead = isRead
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case feedId = "feed_id", subscriptionId = "subscription_id", itemId = "item_id"
        case sortKey = "sort_key", guid, title, author, url
        case publishedAt = "published_at", updatedAt = "updated_at", fetchedAt = "fetched_at"
        case fetchedKey = "fetched_key", summaryHtml = "summary_html", contentHtml = "content_html"
        case isRead = "is_read", isFavorite = "is_favorite"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedId = try container.decode(String.self, forKey: .feedId)
        sortKey = try container.decode(String.self, forKey: .sortKey)
        subscriptionId = try container.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId) ?? ""
        guid = try container.decodeIfPresent(String.self, forKey: .guid) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt) ?? ""
        fetchedKey = try container.decodeIfPresent(String.self, forKey: .fetchedKey) ?? ""
        summaryHtml = try container.decodeIfPresent(String.self, forKey: .summaryHtml) ?? ""
        contentHtml = try container.decodeIfPresent(String.self, forKey: .contentHtml) ?? ""
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

/// A page of the merged listing form of `/rss_list_items`.
public struct RssItemsPage: Sendable, Codable, Hashable {
    public var items: [RssItem]
    public var nextCursor: String?

    public init(items: [RssItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case items, nextCursor = "next_cursor"
    }
}

/// A page of the since-sync form of `/rss_list_items`.
public struct RssSyncPage: Sendable, Codable, Hashable {
    public var items: [RssItem]
    public var nextSince: String
    public var hasMore: Bool

    public init(items: [RssItem], nextSince: String, hasMore: Bool) {
        self.items = items
        self.nextSince = nextSince
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case items, nextSince = "next_since", hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([RssItem].self, forKey: .items) ?? []
        nextSince = try container.decodeIfPresent(String.self, forKey: .nextSince) ?? ""
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

// MARK: - Mutations

/// `/rss_subscribe`.
public struct RssSubscribeResult: Sendable, Codable, Hashable {
    public var subscription: RssSubscription
    public var existing: Bool

    public init(subscription: RssSubscription, existing: Bool) {
        self.subscription = subscription
        self.existing = existing
    }
}

/// `/rss_unsubscribe`.
public struct RssUnsubscribeResult: Sendable, Codable, Hashable {
    public var subscriptionId: String
    public var feedId: String
    public var feedPurged: Bool

    private enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id", feedId = "feed_id", feedPurged = "feed_purged"
    }
}

/// The optional fields of `/rss_update_subscription`; nil means "leave alone".
public struct RssSubscriptionUpdate: Sendable, Hashable {
    public var customTitle: String?
    /// "" moves the subscription to the root.
    public var folderId: String?
    public var orderingMode: RssOrderingMode?
    public var defaultOpenMode: RssOpenMode?
    public var defaultStyling: RssStyling?
    public var notificationsEnabled: Bool?

    public init(
        customTitle: String? = nil, folderId: String? = nil, orderingMode: RssOrderingMode? = nil,
        defaultOpenMode: RssOpenMode? = nil, defaultStyling: RssStyling? = nil,
        notificationsEnabled: Bool? = nil
    ) {
        self.customTitle = customTitle
        self.folderId = folderId
        self.orderingMode = orderingMode
        self.defaultOpenMode = defaultOpenMode
        self.defaultStyling = defaultStyling
        self.notificationsEnabled = notificationsEnabled
    }

    var isEmpty: Bool {
        customTitle == nil && folderId == nil && orderingMode == nil && defaultOpenMode == nil
            && defaultStyling == nil && notificationsEnabled == nil
    }
}

/// The optional fields of `/rss_update_folder`; nil means "leave alone".
public struct RssFolderUpdate: Sendable, Hashable {
    public var name: String?
    /// "" moves the folder to the root.
    public var parentFolderId: String?
    public var displayOrder: Int?

    public init(name: String? = nil, parentFolderId: String? = nil, displayOrder: Int? = nil) {
        self.name = name
        self.parentFolderId = parentFolderId
        self.displayOrder = displayOrder
    }
}

/// `/rss_delete_folder`.
public struct RssFolderDeleteResult: Sendable, Codable, Hashable {
    public var folderId: String
    public var movedSubscriptions: Int
    public var movedFolders: Int
    public var parentFolderId: String

    private enum CodingKeys: String, CodingKey {
        case folderId = "folder_id", movedSubscriptions = "moved_subscriptions"
        case movedFolders = "moved_folders", parentFolderId = "parent_folder_id"
    }
}

/// One entry of `/rss_set_item_state`'s batch.
public struct RssItemStateChange: Sendable, Hashable {
    public var feedId: String
    public var sortKey: String
    public var isRead: Bool?
    public var isFavorite: Bool?

    public init(feedId: String, sortKey: String, isRead: Bool? = nil, isFavorite: Bool? = nil) {
        self.feedId = feedId
        self.sortKey = sortKey
        self.isRead = isRead
        self.isFavorite = isFavorite
    }
}

/// `/rss_mark_all_read`.
public struct RssMarkAllReadResult: Sendable, Codable, Hashable {
    public var subscriptions: Int
    public var flipped: Int
    public var readWatermark: String

    private enum CodingKeys: String, CodingKey {
        case subscriptions, flipped, readWatermark = "read_watermark"
    }
}

/// One rejected entry of an OPML import.
public struct RssOpmlImportFailure: Sendable, Codable, Hashable {
    public var url: String
    public var code: String
    public var message: String

    private enum CodingKeys: String, CodingKey {
        case url, code, message = "Error"
    }
}

/// `/rss_opml_import`.
public struct RssOpmlImportResult: Sendable, Codable, Hashable {
    public var created: Int
    public var existing: Int
    public var foldersCreated: Int
    public var failed: [RssOpmlImportFailure]

    private enum CodingKeys: String, CodingKey {
        case created, existing, foldersCreated = "folders_created", failed
    }
}

/// `/rss_opml_export`.
public struct RssOpmlExport: Sendable, Codable, Hashable {
    public var opml: String
    public var filename: String
}
