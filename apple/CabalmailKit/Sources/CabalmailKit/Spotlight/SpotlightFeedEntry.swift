import Foundation

/// Core Spotlight identity for one indexed feed item: the feed it came from
/// and its sort key there, the pair `ItemRef.feed`, a window's route and the
/// resume session name an item by. The store deletes a feed's items by feed,
/// and a tapped result is looked up by both, so the searchable item's
/// `uniqueIdentifier` is rebuilt from the two alone.
public struct SpotlightFeedItemRef: Sendable, Hashable {
    public let feedID: String
    public let sortKey: String

    public init(feedID: String, sortKey: String) {
        self.feedID = feedID
        self.sortKey = sortKey
    }

    private static let prefix = "cabalmail-feed"
    private static let version = "v1"

    /// Encodes as `cabalmail-feed|v1|<base64url feed id>|<base64url sort
    /// key>`. Both parts are encoded: a sort key is a timestamp and an item
    /// id joined by `#`, and neither part is the client's to constrain.
    public var stringValue: String {
        [
            Self.prefix, Self.version,
            Data(feedID.utf8).base64URLEncoded(), Data(sortKey.utf8).base64URLEncoded(),
        ].joined(separator: "|")
    }

    /// Parses an identifier produced by `stringValue`. Nil for anything
    /// else: a message's identifier (`SpotlightMessageRef`), another app's.
    public init?(string: String) {
        let parts = string.split(separator: "|", omittingEmptySubsequences: false)
        guard
            parts.count == 4,
            parts[0] == Self.prefix,
            parts[1] == Self.version,
            let feedID = Self.decoded(parts[2]), !feedID.isEmpty,
            let sortKey = Self.decoded(parts[3]), !sortKey.isEmpty
        else { return nil }
        self.feedID = feedID
        self.sortKey = sortKey
    }

    private static func decoded(_ part: Substring) -> String? {
        Data(base64URLEncoded: String(part)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The item among everything the app reads.
    public var itemRef: ItemRef { .feed(feedID: feedID, sortKey: sortKey) }

    /// The Spotlight domain of one feed's items, so a feed that leaves is
    /// one `deleteDomains` call.
    ///
    /// Mail's domains are folder paths (`SpotlightEntry.domainIdentifier`),
    /// and unsubscribing a mail folder deletes the domain of that name, so a
    /// feed's domain must not be a name a mail folder could plausibly have.
    /// It has no `.`, which Core Spotlight reads as a hierarchy separator: a
    /// dotted name would put every feed under one parent domain that a mail
    /// folder of the parent's name would delete. What is left is a mail
    /// folder whose whole path is this prefix followed by the encoding of
    /// one feed's id.
    public static func domainIdentifier(feedID: String) -> String {
        "cabalmail-feed-" + Data(feedID.utf8).base64URLEncoded()
    }
}

/// One feed item as donated to the on-device Spotlight index. A pure value,
/// like a message's `SpotlightEntry`, so what an entry says is testable
/// without CoreSpotlight; the `CSSearchableItem` mapping is in
/// `LiveSearchableIndex`'s file.
///
/// It stays on the device, as a message's entry does: the items are already
/// in the feed store on disk, text and all.
public struct SpotlightFeedEntry: Sendable, Hashable {
    public let ref: SpotlightFeedItemRef
    public let title: String
    public let authorNames: [String]
    public let date: Date?
    /// The item's prose, cut at `maxTextLength`; nil when it has none.
    public let textContent: String?

    /// - Parameter maxTextLength: the most text donated for one item, the
    ///   cap a read message's body is cut at.
    public init(text item: RssItemText, maxTextLength: Int) {
        ref = SpotlightFeedItemRef(feedID: item.feedId, sortKey: item.sortKey)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the item list and the reader call an item with no title.
        self.title = title.isEmpty ? "Untitled" : title
        let author = item.author.trimmingCharacters(in: .whitespacesAndNewlines)
        authorNames = author.isEmpty ? [] : [author]
        date = Self.date(item.publishedAt)
        textContent = item.text.isEmpty ? nil : String(item.text.prefix(maxTextLength))
    }

    public var domainIdentifier: String { SpotlightFeedItemRef.domainIdentifier(feedID: ref.feedID) }

    public var uniqueIdentifier: String { ref.stringValue }

    /// The second line of a result: the start of the item's text, else its
    /// author.
    public var contentDescription: String? {
        SpotlightEntry.snippet(from: textContent) ?? authorNames.first
    }

    // Format styles, not `ISO8601DateFormatter`: they are Sendable values,
    // so they can be statics (the feed list's `FeedItemDate` has the long
    // form of this note).
    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func date(_ iso8601: String) -> Date? {
        (try? iso.parse(iso8601)) ?? (try? isoFractional.parse(iso8601))
    }
}
