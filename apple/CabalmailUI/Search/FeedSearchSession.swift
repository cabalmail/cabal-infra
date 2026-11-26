import Foundation
import Observation
import CabalmailKit

/// The feed half of a window's search: the cached articles the search
/// matches, read from the device's feed store a page at a time.
///
/// Nothing here reaches the server, so the half answers at once and works
/// offline; it covers what the device has downloaded and nothing older.
/// Marks made on a row go through the sync engine, as a feed list's do, and
/// the rows are then what the store holds.
@Observable
@MainActor
final class FeedSearchSession {
    /// Rows a read asks for: the first page, and each one after it.
    static let pageSize = 50

    /// The search the rows answer; nil while there is none.
    private(set) var search: RssStore.ItemSearch?
    private(set) var rows: [RssItem] = []
    /// How many cached articles the search matches in all.
    private(set) var total = 0
    /// The search has been read at least once.
    private(set) var loaded = false
    /// The store could not be read.
    private(set) var failed = false
    private(set) var isLoadingMore = false
    /// Each feed's name by subscription, for its rows.
    private(set) var titles: [String: String] = [:]
    /// Rows with a queued (not yet pushed) change, for the row mark.
    private(set) var pendingIDs: Set<String> = []

    /// Counts the searches begun, so a read that lands after a newer search
    /// or a clear brings nothing.
    @ObservationIgnored private var generation = 0

    var hasMore: Bool { rows.count < total }

    func feedName(for item: RssItem) -> String {
        titles[item.subscriptionId] ?? ""
    }

    /// Reads `search` from the top. The rows of the search before it stay
    /// on screen until this one's land, unless it is a different search,
    /// whose section then draws nothing until its own rows are read.
    func run(_ search: RssStore.ItemSearch, in feeds: FlaggedFeedStore) async {
        if search != self.search {
            rows = []
            loaded = false
        }
        self.search = search
        generation += 1
        await read(limit: Self.pageSize, appending: false, in: feeds)
    }

    /// Reads the search again as deep as it is loaded: after a mark, or
    /// when the store changes under it.
    func reload(in feeds: FlaggedFeedStore) async {
        guard search != nil else { return }
        await read(limit: max(rows.count, Self.pageSize), appending: false, in: feeds)
    }

    /// The next page, when there is one and none is being read.
    func loadMore(in feeds: FlaggedFeedStore) async {
        guard search != nil, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await read(limit: Self.pageSize, appending: true, in: feeds)
    }

    /// Ends the search: its rows, its count and what it was.
    func clear() {
        generation += 1
        search = nil
        rows = []
        total = 0
        loaded = false
        failed = false
        pendingIDs = []
    }

    /// Follows the store for as long as the caller's task runs, so a mark
    /// made in a reader, in another window or by a sync shows on the rows.
    func observe(in feeds: FlaggedFeedStore) async {
        guard let store = feeds.store else { return }
        for await _ in await store.changes() {
            await reload(in: feeds)
        }
    }

    // MARK: A row's marks

    func setRead(_ item: RssItem, _ isRead: Bool, in feeds: FlaggedFeedStore) async {
        await mark(item, .read(isRead), in: feeds)
    }

    /// Read to unread and back, judged by what the store holds: the
    /// caller's copy can be the reader's, older than the last mark.
    func toggleRead(_ item: RssItem, in feeds: FlaggedFeedStore) async {
        let stored = await feeds.stored(item) ?? item
        await setRead(item, !stored.isRead, in: feeds)
    }

    /// Sets the flag in palette slot `slot` on an item that lacks it and
    /// clears it on one that carries it, judged by what the store holds.
    func toggleFlag(slot: String, on item: RssItem, in feeds: FlaggedFeedStore) async {
        let stored = await feeds.stored(item) ?? item
        await mark(item, .flag(slot: slot, isSet: !stored.carries(slot: slot)), in: feeds)
    }

    /// A control's mark on a row: shown at once, then written and sent;
    /// afterwards the rows are what the store holds, since a row the mark
    /// takes out of the search (read, under Unread) leaves it.
    private func mark(_ item: RssItem, _ mark: FeedItemMark, in feeds: FlaggedFeedStore) async {
        guard feeds.engine != nil else { return }
        if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index].apply(mark) }
        _ = await feeds.write(mark, to: item)
        await reload(in: feeds)
    }

    // MARK: Reading

    private func read(limit: Int, appending: Bool, in feeds: FlaggedFeedStore) async {
        guard let search, let store = feeds.store else {
            if feeds.store == nil { loaded = true }
            return
        }
        let asked = generation
        let cursor = appending ? rows.last.map(RssStore.ItemCursor.init(after:)) : nil
        let page = try? await store.search(search, limit: limit, after: cursor)
        let count = try? await store.searchCount(search)
        let subscriptions = try? await store.subscriptions()
        guard asked == generation else { return }
        guard let page, let count else {
            failed = true
            loaded = true
            return
        }
        var pending: Set<String> = appending ? pendingIDs : []
        for item in page where (try? await store.hasPending(feedId: item.feedId, sortKey: item.sortKey)) == true {
            pending.insert(item.id)
        }
        guard asked == generation else { return }
        let known = Set(rows.map(\.id))
        rows = appending ? rows + page.filter { !known.contains($0.id) } : page
        total = max(count, rows.count)
        pendingIDs = pending
        if let subscriptions {
            titles = Dictionary(
                subscriptions.map { ($0.subscriptionId, $0.displayTitle) }, uniquingKeysWith: { first, _ in first }
            )
        }
        failed = false
        loaded = true
    }
}
