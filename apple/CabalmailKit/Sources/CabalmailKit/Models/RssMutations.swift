import Foundation

// Wire types for the RSS reader API's mutations (`docs/rss.md`): the request
// shapes the clients build and the results the Lambdas return. Split from
// `Rss.swift` (the catalog and item types) for the file-length cap; the same
// additive-evolution and lenient-decode rules apply.

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
    public var defaultRemoteContent: RssRemoteContentMode?
    public var notificationsEnabled: Bool?

    public init(
        customTitle: String? = nil, folderId: String? = nil, orderingMode: RssOrderingMode? = nil,
        defaultOpenMode: RssOpenMode? = nil, defaultStyling: RssStyling? = nil,
        defaultRemoteContent: RssRemoteContentMode? = nil, notificationsEnabled: Bool? = nil
    ) {
        self.customTitle = customTitle
        self.folderId = folderId
        self.orderingMode = orderingMode
        self.defaultOpenMode = defaultOpenMode
        self.defaultStyling = defaultStyling
        self.defaultRemoteContent = defaultRemoteContent
        self.notificationsEnabled = notificationsEnabled
    }

    public var isEmpty: Bool {
        customTitle == nil && folderId == nil && orderingMode == nil && defaultOpenMode == nil
            && defaultStyling == nil && defaultRemoteContent == nil && notificationsEnabled == nil
    }
}

extension RssSubscription {
    /// This subscription with `update`'s fields applied — what the server
    /// will return, computed locally so a settings change can take effect
    /// (and be cached) before the round trip completes.
    public func applying(_ update: RssSubscriptionUpdate) -> RssSubscription {
        var sub = self
        if let value = update.customTitle { sub.customTitle = value }
        if let value = update.folderId { sub.folderId = value }
        if let value = update.orderingMode { sub.orderingMode = value }
        if let value = update.defaultOpenMode { sub.defaultOpenMode = value }
        if let value = update.defaultStyling { sub.defaultStyling = value }
        if let value = update.defaultRemoteContent { sub.defaultRemoteContent = value }
        if let value = update.notificationsEnabled { sub.notificationsEnabled = value }
        return sub
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
