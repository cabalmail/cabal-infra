import Foundation

// The local "resume where you left off" layer: what this install had on
// screen when the app last went away, plus per-item reading positions. Both
// are device-scoped by design and never leave the device — the server-side
// `NavState` cursor is the *cross-device* signal and stays separate. See
// `docs/1.x/resume-session-plan.md`.

/// The section, list scope, and open item the app last showed. Mail and feed
/// positions are kept independently so a user who switches sections and back
/// within one relaunch gets both restored.
public struct ResumeSession: Codable, Equatable, Sendable {
    public enum Section: String, Codable, Sendable {
        case mail
        case feeds
    }

    public var section: Section
    // Mail position.
    public var folder: String?
    public var uid: UInt32?
    public var messageID: String?
    // Feed position. The item is stored as the pair `RssStore.item(feedId:
    // sortKey:)` looks up rather than `RssItem.id`, which is derived from it.
    public var feedScope: RssItemScope?
    public var feedItemFeedID: String?
    public var feedItemSortKey: String?
    public var savedAt: Date

    public init(
        section: Section = .mail,
        folder: String? = nil,
        uid: UInt32? = nil,
        messageID: String? = nil,
        feedScope: RssItemScope? = nil,
        feedItemFeedID: String? = nil,
        feedItemSortKey: String? = nil,
        savedAt: Date = Date()
    ) {
        self.section = section
        self.folder = folder
        self.uid = uid
        self.messageID = messageID
        self.feedScope = feedScope
        self.feedItemFeedID = feedItemFeedID
        self.feedItemSortKey = feedItemSortKey
        self.savedAt = savedAt
    }

    public var hasMessage: Bool { uid != nil || messageID != nil }
    public var hasFeedItem: Bool { feedItemFeedID != nil && feedItemSortKey != nil }

    /// Clears the open feed item while keeping the scope (back to the list).
    public mutating func clearFeedItem() {
        feedItemFeedID = nil
        feedItemSortKey = nil
    }

    /// Clears the open message while keeping the folder (back to the list).
    public mutating func clearMessage() {
        uid = nil
        messageID = nil
    }
}

/// Where the reader was in one item's body: a DOM anchor for an HTML body
/// (the same `i<path>|<delta>` / `f<fraction>` form the server cursor's
/// `msg_anchor` carries) or an exact offset for plain text. One or the other.
public struct ReadingPosition: Codable, Equatable, Sendable {
    public var anchor: String?
    public var offset: Int?
    public var savedAt: Date

    public init(anchor: String? = nil, offset: Int? = nil, savedAt: Date = Date()) {
        self.anchor = anchor
        self.offset = offset
        self.savedAt = savedAt
    }
}

/// Keys for `ReadingPositionCache`, one scheme per item kind so a mail
/// message and a feed item can never collide.
public enum ReadingPositionKey {
    /// Message-ID when known — it survives a move between folders — else the
    /// folder + UID the reader was opened with.
    public static func mail(messageID: String?, folder: String, uid: UInt32) -> String {
        if let messageID, !messageID.isEmpty {
            return "mail:\(messageID)"
        }
        return "mail:\(folder)#\(uid)"
    }

    /// `RssItem.id` (`<feedId>#<sortKey>`), stable across feeds.
    public static func feed(itemID: String) -> String {
        "feed:\(itemID)"
    }
}

/// Bounded, least-recently-written cache of reading positions keyed by
/// `ReadingPositionKey`. Reads don't reorder — a reopened item captures a
/// fresh position almost immediately, which is the recency signal that
/// matters — so `position(for:)` stays non-mutating.
public struct ReadingPositionCache: Codable, Equatable, Sendable {
    public static let defaultCapacity = 200

    public private(set) var entries: [String: ReadingPosition]
    /// Insertion/refresh order, oldest first; the eviction queue.
    public private(set) var order: [String]
    public let capacity: Int

    public init(capacity: Int = ReadingPositionCache.defaultCapacity) {
        self.entries = [:]
        self.order = []
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    public func position(for key: String) -> ReadingPosition? {
        entries[key]
    }

    /// Stores `position` under `key`, refreshing its recency, and evicts the
    /// oldest entries past `capacity`.
    public mutating func set(_ position: ReadingPosition, for key: String) {
        if entries[key] != nil {
            order.removeAll { $0 == key }
        }
        entries[key] = position
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    public mutating func remove(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    /// Defensive decode: a hand-edited or partially written blob must never
    /// leave `order` and `entries` disagreeing, so `order` is rebuilt from the
    /// entries it actually names.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([String: ReadingPosition].self, forKey: .entries) ?? [:]
        let order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        let capacity = try container.decodeIfPresent(Int.self, forKey: .capacity)
            ?? ReadingPositionCache.defaultCapacity
        var seen = Set<String>()
        var rebuilt: [String] = []
        for key in order where entries[key] != nil && !seen.contains(key) {
            seen.insert(key)
            rebuilt.append(key)
        }
        for key in entries.keys.sorted() where !seen.contains(key) {
            rebuilt.append(key)
        }
        self.entries = entries
        self.order = rebuilt
        self.capacity = max(1, capacity)
    }

    private enum CodingKeys: String, CodingKey {
        case entries, order, capacity
    }
}

/// `UserDefaults`-backed persistence for the resume layer: the session
/// record, the reading-position cache, and the newest cross-device cursor
/// this install has already offered (so an ignored "pick up where you left
/// off" toast isn't re-offered on the next launch).
///
/// Deliberately plain `UserDefaults`, like `InstallIdentity` and the push
/// settings — never the account-scoped, server-synced preferences: this
/// state is inherently per install. Cleared on sign-out so the next account
/// on the device starts fresh.
public final class ResumeSessionStore: @unchecked Sendable {
    public static let sessionKey = "cabalmail.resume.session"
    public static let positionsKey = "cabalmail.resume.positions"
    public static let offeredForeignUpdatedAtKey = "cabalmail.resume.offeredForeignUpdatedAt"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func loadSession() -> ResumeSession? {
        guard let data = defaults.data(forKey: Self.sessionKey) else { return nil }
        return try? decoder.decode(ResumeSession.self, from: data)
    }

    public func saveSession(_ session: ResumeSession) {
        guard let data = try? encoder.encode(session) else { return }
        defaults.set(data, forKey: Self.sessionKey)
    }

    public func loadPositions() -> ReadingPositionCache {
        guard let data = defaults.data(forKey: Self.positionsKey),
              let cache = try? decoder.decode(ReadingPositionCache.self, from: data)
        else { return ReadingPositionCache() }
        return cache
    }

    public func savePositions(_ cache: ReadingPositionCache) {
        guard let data = try? encoder.encode(cache) else { return }
        defaults.set(data, forKey: Self.positionsKey)
    }

    /// Server `updated_at` (epoch ms) of the newest foreign cursor already
    /// surfaced to the user; 0 when none has been.
    public var offeredForeignUpdatedAt: Int64 {
        get { Int64(defaults.integer(forKey: Self.offeredForeignUpdatedAtKey)) }
        set { defaults.set(Int(newValue), forKey: Self.offeredForeignUpdatedAtKey) }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.sessionKey)
        defaults.removeObject(forKey: Self.positionsKey)
        defaults.removeObject(forKey: Self.offeredForeignUpdatedAtKey)
    }

    /// Synchronous read of the stored section, for SwiftUI property
    /// initialisers that must pick the launch tab before the first frame (a
    /// `@State` default can't reach the environment, and seeding it a frame
    /// later would flash Mail before switching to Feeds).
    public static func storedSection(defaults: UserDefaults = .standard) -> ResumeSession.Section? {
        ResumeSessionStore(defaults: defaults).loadSession()?.section
    }
}
