import Foundation

/// Whoever mirrors the feed store's items outside the store: on the app's
/// platforms, the Spotlight index (`SpotlightIndexer`).
///
/// `RssSyncEngine` tells it what it writes, after the store has it: the
/// items of each page it stores, and the feeds whose items the store deleted
/// because their subscription left. A protocol declared here, so the feed
/// code does not depend on what mirrors it.
///
/// Neither call may wait on the mirror. A sync that waited for a system
/// index to take its items would stop when that index does, and every later
/// sync of the feed joins the one in flight; so the two are synchronous, and
/// an implementation queues what it is told and returns.
///
/// Nothing is said at sign-out: the store's `clear()` is the client's to
/// call, and the client wipes the mirror itself
/// (`CabalmailClient.clearLocalData()`).
public protocol RssItemIndexing: Sendable {
    /// The engine stored `items` (a feed's first fill, a sync page, a page
    /// of older items).
    func itemsStored(_ items: [RssItem])
    /// The store deleted every item of these feeds.
    func feedsRemoved(_ feedIDs: [String])
}

/// A feed item as a search index sees it: its identity, what it is called
/// and its prose, with no markup.
///
/// Built from an item in hand, or read back from the store
/// (`RssStore.newestItemText`), which keeps the same text for its own
/// search; both give one text for one item.
public struct RssItemText: Sendable, Hashable {
    public var feedId: String
    public var sortKey: String
    public var title: String
    public var author: String
    /// ISO 8601, as the item carries it.
    public var publishedAt: String
    /// The body as plain text: the content, else the summary.
    public var text: String

    public init(
        feedId: String, sortKey: String, title: String = "", author: String = "", publishedAt: String = "",
        text: String = ""
    ) {
        self.feedId = feedId
        self.sortKey = sortKey
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.text = text
    }

    /// `item`'s text. Parses its HTML, as the store does when it writes the
    /// item, so this is for a page just synced and not for a whole feed.
    public init(item: RssItem) {
        self.init(
            feedId: item.feedId, sortKey: item.sortKey, title: item.title, author: item.author,
            publishedAt: item.publishedAt, text: HTMLText.plainText(from: item.bodyHtml)
        )
    }
}
