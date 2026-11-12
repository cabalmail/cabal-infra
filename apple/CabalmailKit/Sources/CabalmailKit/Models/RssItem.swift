import Foundation

// The item half of the RSS reader's wire types (`docs/rss.md`): an item, a
// row of the caller's per-item state, and the pages they arrive in. The
// catalog half is `Rss.swift`.

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
    /// Whether `isRead` is the user's own mark (server state row) rather
    /// than the subscription's read watermark. An explicit mark is exempt
    /// from the local watermark rule, so a mark-unread on an old item
    /// survives a later listing.
    public var isReadExplicit: Bool
    public var isFavorite: Bool
    /// The item's custom flags: keyword slots of the flag palette
    /// (`FlagPalette.slots`), the vocabulary mail keywords use. The system
    /// flag is never among them; on a feed item it is `isFavorite`. A slot
    /// whose palette entry is disabled or gone stays here.
    public var flags: Set<String>

    /// Stable across feeds: two feeds could carry the same sort key.
    public var id: String { "\(feedId)#\(sortKey)" }

    /// The body to render: the full content when the feed delivered it,
    /// else the summary.
    public var bodyHtml: String { contentHtml.isEmpty ? summaryHtml : contentHtml }

    public init(
        feedId: String, subscriptionId: String = "", itemId: String, sortKey: String, guid: String = "",
        title: String = "", author: String = "", url: String = "", publishedAt: String = "",
        updatedAt: String = "", fetchedAt: String = "", fetchedKey: String = "",
        summaryHtml: String = "", contentHtml: String = "", isRead: Bool = false, isReadExplicit: Bool = false,
        isFavorite: Bool = false, flags: Set<String> = []
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
        self.isReadExplicit = isReadExplicit
        self.isFavorite = isFavorite
        self.flags = flags
    }

    private enum CodingKeys: String, CodingKey {
        case feedId = "feed_id", subscriptionId = "subscription_id", itemId = "item_id"
        case sortKey = "sort_key", guid, title, author, url
        case publishedAt = "published_at", updatedAt = "updated_at", fetchedAt = "fetched_at"
        case fetchedKey = "fetched_key", summaryHtml = "summary_html", contentHtml = "content_html"
        case isRead = "is_read", isReadExplicit = "is_read_explicit", isFavorite = "is_favorite", flags
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
        isReadExplicit = try container.decodeIfPresent(Bool.self, forKey: .isReadExplicit) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        flags = Set(try container.decodeIfPresent([String].self, forKey: .flags) ?? [])
    }
}

/// One row of the caller's per-item state, from the state-sync form of
/// `/rss_list_items`: the marks and custom flags an item carries, keyed so
/// they can be applied to the cached copy.
public struct RssItemState: Sendable, Codable, Hashable {
    public var feedId: String
    public var sortKey: String
    public var isRead: Bool
    public var isReadExplicit: Bool
    public var isFavorite: Bool
    /// The item's custom flags, as `RssItem.flags`.
    public var flags: Set<String>
    public var updatedAt: String

    public init(feedId: String, sortKey: String, isRead: Bool = false, isReadExplicit: Bool = false,
                isFavorite: Bool = false, flags: Set<String> = [], updatedAt: String = "") {
        self.feedId = feedId
        self.sortKey = sortKey
        self.isRead = isRead
        self.isReadExplicit = isReadExplicit
        self.isFavorite = isFavorite
        self.flags = flags
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case feedId = "feed_id", sortKey = "sort_key", isRead = "is_read"
        case isReadExplicit = "is_read_explicit", isFavorite = "is_favorite", flags, updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedId = try container.decode(String.self, forKey: .feedId)
        sortKey = try container.decode(String.self, forKey: .sortKey)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isReadExplicit = try container.decodeIfPresent(Bool.self, forKey: .isReadExplicit) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        flags = Set(try container.decodeIfPresent([String].self, forKey: .flags) ?? [])
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

/// A page of the state-sync form of `/rss_list_items`. `nextSince` is
/// opaque: pass it back unchanged.
public struct RssStateSyncPage: Sendable, Codable, Hashable {
    public var states: [RssItemState]
    public var nextSince: String
    public var hasMore: Bool

    public init(states: [RssItemState], nextSince: String, hasMore: Bool) {
        self.states = states
        self.nextSince = nextSince
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case states, nextSince = "next_state_since", hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        states = try container.decodeIfPresent([RssItemState].self, forKey: .states) ?? []
        nextSince = try container.decodeIfPresent(String.self, forKey: .nextSince) ?? ""
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
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
