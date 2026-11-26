import Foundation
import CabalmailKit

/// The Flagged view's feed half: the flagged feed items read from the
/// device's store so far, newest first, with what a row draws beside them.
struct FlaggedFeedHalf {
    private(set) var items: [RssItem] = []
    /// Whether the store may hold more than was read.
    private(set) var hasMore = false
    /// Whether the half has been read at least once for this pick.
    private(set) var loaded = false
    /// How many items the pick finds in the store.
    private(set) var count: Int?
    /// Items with a queued (not yet pushed) change, for the row mark.
    private(set) var pendingIDs: Set<String> = []
    /// Subscription id to display title, for a row's caption.
    private(set) var titles: [String: String] = [:]

    /// One read of the store (`FlaggedFeedStore.read`).
    struct Read {
        var items: [RssItem]
        var limit: Int
        var count: Int?
        var pendingIDs: Set<String>
        var titles: [String: String]?
    }

    /// The limit and the cursor the next read asks with: again from the
    /// top, as many rows as are loaded, or with `more` the page after them.
    func query(matching criterion: FlagCriterion, more: Bool) -> RssStore.ItemQuery {
        RssStore.ItemQuery(
            scope: .all, flag: criterion, ordering: .newestFirst,
            limit: more ? FlaggedList.feedPageSize : max(items.count, FlaggedList.feedPageSize),
            after: more ? items.last.map(RssStore.ItemCursor.init(after:)) : nil
        )
    }

    mutating func land(_ read: Read, more: Bool) {
        if more {
            let shown = Set(items.map(\.id))
            items += read.items.filter { !shown.contains($0.id) }
            pendingIDs.formUnion(read.pendingIDs)
        } else {
            items = read.items
            pendingIDs = read.pendingIDs
        }
        hasMore = read.items.count == read.limit
        loaded = true
        count = read.count
        if let titles = read.titles { self.titles = titles }
    }

    /// The store could not be had at all: the half is whole, and empty.
    mutating func landNothing() {
        loaded = true
    }

    /// A control's mark on a row, shown ahead of the store's write.
    /// Returns whether a row changed.
    mutating func apply(_ mark: FeedItemMark, to item: RssItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        items[index].apply(mark)
        return true
    }

    /// The rows the pick still finds, ahead of the next read.
    func matching(_ criterion: FlagCriterion) -> [RssItem] {
        items.filter { criterion.matches($0.paletteFlags) }
    }

    var cutoff: Date? {
        FlaggedList.feedCutoff(loaded: items, hasMore: hasMore)
    }
}

/// The Flagged view's reads and writes of the device's feed store, and the
/// sync that brings it up to date. Nil members are a bare client's, where
/// every read finds nothing and every write does nothing.
struct FlaggedFeedStore {
    let store: RssStore?
    let engine: RssSyncEngine?

    /// One page of the feed half, with what its rows draw beside them: the
    /// pick's count, the feeds' titles and the queued marks. Nil when the
    /// store could not be read.
    func read(_ query: RssStore.ItemQuery) async -> FlaggedFeedHalf.Read? {
        guard let store, let flag = query.flag, let rows = try? await store.items(query) else { return nil }
        var read = FlaggedFeedHalf.Read(items: rows, limit: query.limit, pendingIDs: [])
        read.count = try? await store.flagCount(in: .all, matching: flag)
        read.titles = (try? await store.subscriptions()).map { subscriptions in
            Dictionary(
                subscriptions.map { ($0.subscriptionId, $0.displayTitle) }, uniquingKeysWith: { first, _ in first }
            )
        }
        for item in rows where (try? await store.hasPending(feedId: item.feedId, sortKey: item.sortKey)) == true {
            read.pendingIDs.insert(item.id)
        }
        return read
    }

    /// Fresh items and marks from the server for every feed, so a flag set
    /// on another device shows.
    func sync() async {
        _ = await engine?.syncItems(in: .all)
    }

    /// The item as the store holds it now.
    func stored(_ item: RssItem) async -> RssItem? {
        (try? await store?.item(feedId: item.feedId, sortKey: item.sortKey)) ?? nil
    }

    /// Writes one mark through the sync engine, the store first and then a
    /// push. Returns whether there was an engine to write through.
    func write(_ mark: FeedItemMark, to item: RssItem) async -> Bool {
        guard let engine else { return false }
        try? await engine.write(mark, to: item)
        return true
    }
}
