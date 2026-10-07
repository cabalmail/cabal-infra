import Foundation
import Observation
import CabalmailKit

/// Backs `FeedItemListView`: one page of items for a scope from the local
/// store, the all / unread / favorite filter, the subscription's ordering,
/// per-feed search, and the optimistic read / favorite mutations.
///
/// The filter pill is sticky per scope: the list opens on the pill the user
/// last chose for this feed (`RssSubscription.defaultFilter`), folder
/// (`RssFolder.defaultFilter`), or the all-feeds list
/// (`Preferences.rssAllFeedsFilter`) -- Unread until then -- and a tap
/// writes the pill back there (`selectFilter`). A single feed's order is
/// sticky the same way (`RssSubscription.orderingMode`, `selectOrdering`).
/// The rows sync through the server, so the choices follow the account
/// across devices.
///
/// Everything the list shows comes from `RssStore`; the network only runs
/// in `sync()` (fresh items) and `loadOlder()` (history), both of which
/// re-read the store afterwards. `observe()` keeps the list current with
/// writes made anywhere else: a row patches in place, and a sync or a
/// catalog change re-reads the first page.
@Observable
@MainActor
final class FeedItemListViewModel {
    let scope: RssItemScope
    var items: [RssItem] = []
    /// The active pill. Set through `selectFilter` from the UI; a direct
    /// assignment reloads without recording the choice.
    var filter: RssItemFilter {
        didSet { Task { await reload() } }
    }
    /// The active order. Set through `selectOrdering` from the Order menu;
    /// the view reloads when it changes.
    var ordering: RssOrderingMode
    var searchQuery = "" {
        didSet { Task { await reload() } }
    }
    var isSyncing = false
    var isLoadingOlder = false
    var hasMoreLocal = true
    var olderExhausted = false
    var errorMessage: String?
    /// Items with a queued (not yet pushed) state change, for the row mark.
    var pendingIds: Set<String> = []
    /// Subscription id → display title, for the feed label on rows in
    /// multi-feed scopes. Read with the page; empty in single-feed scope.
    var subscriptionTitles: [String: String] = [:]

    /// The client's `rssStore` / `rssSync`, or a test's. Nil on a bare
    /// client, where every load is a no-op.
    private let store: RssStore?
    private let engine: RssSyncEngine?
    private let preferences: Preferences
    private let defaults: FeedDefaultsPersisting?
    private let pageSize = 100
    /// The feeds this scope covers as of the last read: a sync of one of
    /// them reloads the list, and a catalog change that moves a feed in or
    /// out of the scope does too.
    private var scopeFeedIds: Set<String> = []

    /// The single subscription this list shows, when it shows exactly one;
    /// search, load-older, and the ordering preference only make sense then.
    /// Mutable only so a pill tap can hold the optimistic row (`selectFilter`).
    private(set) var subscription: RssSubscription?
    /// The folder this list shows, in folder scope; same optimistic role.
    private(set) var folder: RssFolder?

    init(scope: RssItemScope, subscription: RssSubscription?, folder: RssFolder? = nil,
         client: CabalmailClient, preferences: Preferences, defaults: FeedDefaultsPersisting? = nil,
         store: RssStore? = nil, engine: RssSyncEngine? = nil) {
        self.scope = scope
        self.subscription = subscription
        self.folder = folder
        let engine = engine ?? client.rssSync
        self.store = store ?? client.rssStore
        self.engine = engine
        self.preferences = preferences
        self.defaults = defaults ?? engine
        self.ordering = FeedListOrderingPolicy.initial(subscription: subscription)
        self.filter = FeedListFilterPolicy.initial(scope: scope, subscription: subscription, folder: folder,
                                                   allFeedsFilter: preferences.rssAllFeedsFilter)
    }

    /// A pill tap: applies the filter, then makes it the pill this scope's
    /// list opens on. Optimistic, like the reader's sticky toggles: the row
    /// held here changes at once, the store and server follow, and a failure
    /// leaves the next catalog refresh to reconcile.
    func selectFilter(_ filter: RssItemFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        switch scope {
        case .all:
            preferences.rssAllFeedsFilter = filter
        case .subscription:
            guard let subscription,
                  let update = FeedListFilterPolicy.stickyUpdate(for: subscription, filter: filter)
            else { return }
            persist(update, to: subscription)
        case .folder:
            guard let folder,
                  let update = FeedListFilterPolicy.stickyUpdate(for: folder, filter: filter)
            else { return }
            persist(update, to: folder)
        }
    }

    /// An Order menu pick: applies the order, then makes it the order this
    /// feed's list opens on, on every device, through the same optimistic
    /// write as the pill. Only a single feed has an order to keep; the menu
    /// is offered only there (`canSearch`).
    func selectOrdering(_ ordering: RssOrderingMode) {
        guard ordering != self.ordering else { return }
        self.ordering = ordering
        guard let subscription,
              let update = FeedListOrderingPolicy.stickyUpdate(for: subscription, ordering: ordering)
        else { return }
        persist(update, to: subscription)
    }

    /// Holds the updated row at once, then writes it through the store to
    /// the server; a failure leaves the next catalog refresh to reconcile.
    /// The store's write tells the sidebar and the settings sheet.
    private func persist(_ update: RssSubscriptionUpdate, to subscription: RssSubscription) {
        guard let defaults else { return }
        self.subscription = subscription.applying(update)
        Task { _ = try? await defaults.updateSubscription(subscription, update) }
    }

    /// The folder counterpart of `persist(_:to:)` for a subscription.
    private func persist(_ update: RssFolderUpdate, to folder: RssFolder) {
        guard let defaults else { return }
        self.folder = folder.applying(update)
        Task { _ = try? await defaults.updateFolder(folder, update) }
    }

    // MARK: - Following the store

    /// The view's `.task` while the list is up: re-reads the first page,
    /// then follows the store's changes until the view goes.
    func observe() async {
        guard let store else { return }
        let changes = await store.changes()
        await reload()
        await FeedStoreChanges.follow(changes) { batch in await apply(batch) }
    }

    /// One batch of store changes. A sync, a mark-all-read or another
    /// device's marks re-read the list while it is still on its first page,
    /// so new items appear; a list the user has paged through keeps its
    /// place and picks them up on its next reload. A changed mark patches
    /// its row in place, so the dot and flag agree without a reload; rows
    /// stay put even when they no longer match the filter, and the next
    /// reload settles that, the same as the list's own swipe actions.
    func apply(_ batch: FeedChangeBatch) async {
        var reloads = batch.cleared
        if batch.catalog, await readCatalog() { reloads = true }
        if !batch.feeds.isDisjoint(with: scopeFeedIds), items.count <= pageSize { reloads = true }
        if reloads {
            await reload()
        } else if !batch.items.isEmpty {
            await patch(batch.items)
        }
    }

    /// What the catalog decides for this list: its subscription or folder
    /// row (sticky defaults, the feed's health), the feed titles on rows, and
    /// which feeds the scope covers. True when the list must reload: the
    /// scope gained or lost a feed, or the feed's order changed in its
    /// settings sheet or on another device.
    private func readCatalog() async -> Bool {
        guard let store else { return false }
        var reloads = false
        switch scope {
        case .subscription(let id):
            if let row = (try? await store.subscription(id: id)) ?? nil {
                subscription = row
                let stored = FeedListOrderingPolicy.initial(subscription: row)
                if stored != ordering {
                    ordering = stored
                    reloads = true
                }
            }
        case .folder(let id):
            if let row = (try? await store.folder(id: id)) ?? nil { folder = row }
        case .all:
            break
        }
        if subscription == nil, let subs = try? await store.subscriptions() {
            subscriptionTitles = Self.titles(of: subs)
        }
        if let feeds = try? await store.feedIds(in: scope), Set(feeds) != scopeFeedIds { reloads = true }
        return reloads
    }

    /// Re-reads the rows the store says changed: their read and flag state
    /// and the queued mark.
    private func patch(_ ids: Set<String>) async {
        guard let store else { return }
        for row in items where ids.contains(row.id) {
            let fresh = (try? await store.item(feedId: row.feedId, sortKey: row.sortKey)) ?? nil
            let queued = (try? await store.hasPending(feedId: row.feedId, sortKey: row.sortKey)) == true
            if let fresh {
                replace(row) {
                    $0.isRead = fresh.isRead
                    $0.isFavorite = fresh.isFavorite
                }
            }
            if queued { pendingIds.insert(row.id) } else { pendingIds.remove(row.id) }
        }
    }

    private static func titles(of subscriptions: [RssSubscription]) -> [String: String] {
        Dictionary(subscriptions.map { ($0.subscriptionId, $0.displayTitle) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The feed label for a row: the subscription's title, else the URL host.
    func feedName(for item: RssItem) -> String {
        FeedItemLabels.feedName(for: item, titles: subscriptionTitles)
    }

    var canSearch: Bool { subscription != nil }
    var canLoadOlder: Bool { subscription != nil && !olderExhausted }

    /// First page from the store.
    func reload() async {
        guard let store else { return }
        do {
            if let subscription {
                // The engine learns on the first sync whether the server has
                // history beyond the first page; without this the button
                // showed for every feed and did nothing for most.
                olderExhausted = try await store.syncState(feedId: subscription.feedId).olderExhausted
            }
            if subscription == nil {
                subscriptionTitles = Self.titles(of: try await store.subscriptions())
            }
            scopeFeedIds = Set(try await store.feedIds(in: scope))
            if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, let subscription {
                items = try await store.search(feedId: subscription.feedId, query: searchQuery)
                hasMoreLocal = false
            } else {
                items = try await store.items(.init(scope: scope, filter: filter, ordering: ordering,
                                                    limit: pageSize))
                hasMoreLocal = items.count == pageSize
            }
            await refreshPendingMarks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Next page from the store (scrolling): the rows that sort after the
    /// last one shown. Keyed, not offset, because the result set moves
    /// under a paged list - rows read in the Unread pill stay on screen
    /// but leave the filter, and syncs insert newer rows above - and an
    /// offset then skips or repeats rows. Anything already shown is
    /// dropped, so `ForEach` never sees a duplicate id.
    func loadMore() async {
        guard hasMoreLocal, let store, searchQuery.isEmpty, let last = items.last else { return }
        do {
            let page = try await store.items(.init(scope: scope, filter: filter, ordering: ordering,
                                                   limit: pageSize, after: .init(after: last)))
            let shown = Set(items.map(\.id))
            items += page.filter { !shown.contains($0.id) }
            hasMoreLocal = page.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fresh items from the server for the feeds in scope, then a reload.
    /// The engine syncs them four at a time, joining any feed another pass
    /// is already syncing, and tries every feed whatever another one does.
    func sync() async {
        guard !isSyncing, let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        let report = await engine.syncItems(in: scope)
        // A sync whose task was cancelled has nothing to report: the list's
        // `.task` as it leaves the screen mid-sync (a pushed reader or a tab
        // switch on iPhone, a scope change), or a pull cut short (#1908). It
        // stops waiting at once, and the engine stops the work once nobody
        // waits for it. Read off the task, not the result. An earlier error
        // stands; the store is still re-read below, since feeds synced before
        // the cancel have landed. No retry is armed here: the list's
        // `.task(id: scope)` builds a fresh model and syncs on every
        // appearance; a `model == nil` gate there would need one. A failed
        // drain stays quiet, as before: the queue waits for the next one.
        if let report, !Task.isCancelled {
            errorMessage = (report.catalogError ?? report.firstFeedError).map(FeedErrorText.describe)
        }
        await reload()
    }

    /// Older history for a single feed, then a reload.
    func loadOlder() async {
        guard let subscription, let engine, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let received = try await engine.loadOlder(for: subscription)
            olderExhausted = received == 0
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
        await reload()
    }

    // MARK: - Mutations (optimistic; the engine queues and pushes)

    func setRead(_ item: RssItem, _ isRead: Bool) async {
        guard let engine else { return }
        replace(item) { $0.isRead = isRead }
        try? await engine.setRead(item, isRead)
        await patch([item.id])
    }

    func setFavorite(_ item: RssItem, _ isFavorite: Bool) async {
        guard let engine else { return }
        replace(item) { $0.isFavorite = isFavorite }
        try? await engine.setFavorite(item, isFavorite)
        await patch([item.id])
    }

    /// The swipe bindings, exposed so the row picks the button each edge
    /// reveals without reaching into the preferences environment itself.
    var swipeLeading: FeedSwipeAction { preferences.rssSwipeLeading }
    var swipeTrailing: FeedSwipeAction { preferences.rssSwipeTrailing }

    /// Applies the user's mark-as-read preference when an item opens.
    func didOpen(_ item: RssItem) async {
        guard preferences.rssMarkAsRead == .onOpen, !item.isRead else { return }
        await setRead(item, true)
    }

    func markAllRead() async {
        guard let engine, let store else { return }
        let feedIds = Set((try? await store.feedIds(in: scope)) ?? [])
        let subs = ((try? await store.subscriptions()) ?? []).filter { feedIds.contains($0.feedId) }
        for sub in subs {
            try? await engine.markAllRead(subscriptionId: sub.subscriptionId)
        }
        await reload()
    }

    private func replace(_ item: RssItem, _ change: (inout RssItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        change(&items[index])
    }

    private func refreshPendingMarks() async {
        guard let store else { return }
        var pending: Set<String> = []
        for item in items where (try? await store.hasPending(feedId: item.feedId, sortKey: item.sortKey)) == true {
            pending.insert(item.id)
        }
        pendingIds = pending
    }
}

/// Which pill a feed list opens on, and what a tap writes back. Pure so it
/// can be unit-tested without a client.
enum FeedListFilterPolicy {
    /// The scope's sticky pill: the subscription's or folder's stored
    /// default, or the all-feeds preference. A scope whose row is not at
    /// hand (a folder the store has not seen yet) opens on the feed default.
    static func initial(
        scope: RssItemScope, subscription: RssSubscription?, folder: RssFolder?, allFeedsFilter: RssItemFilter
    ) -> RssItemFilter {
        switch scope {
        case .all: return allFeedsFilter
        case .subscription: return subscription?.defaultFilter ?? .defaultForFeeds
        case .folder: return folder?.defaultFilter ?? .defaultForFeeds
        }
    }

    /// The subscription update a tap on `filter` writes, or nil when the
    /// row already says so.
    static func stickyUpdate(for subscription: RssSubscription, filter: RssItemFilter) -> RssSubscriptionUpdate? {
        subscription.defaultFilter == filter ? nil : RssSubscriptionUpdate(defaultFilter: filter)
    }

    /// The folder counterpart of `stickyUpdate(for:filter:)`.
    static func stickyUpdate(for folder: RssFolder, filter: RssItemFilter) -> RssFolderUpdate? {
        folder.defaultFilter == filter ? nil : RssFolderUpdate(defaultFilter: filter)
    }
}

/// Which order a single feed's list opens on, and what an Order menu pick
/// writes back. Pure so it can be unit-tested without a client.
enum FeedListOrderingPolicy {
    /// The feed's stored order, or newest first for a list with no single
    /// subscription (a folder, All Feeds) or a row not at hand.
    static func initial(subscription: RssSubscription?) -> RssOrderingMode {
        subscription?.orderingMode ?? .newestFirst
    }

    /// The subscription update a pick of `ordering` writes, or nil when the
    /// row already says so.
    static func stickyUpdate(for subscription: RssSubscription, ordering: RssOrderingMode) -> RssSubscriptionUpdate? {
        subscription.orderingMode == ordering ? nil : RssSubscriptionUpdate(orderingMode: ordering)
    }
}

/// Pure helpers for row text, kept out of the model so they can be tested
/// without a client.
enum FeedItemLabels {
    /// The subscription's title when known, else the article URL's host,
    /// else nothing (the row then shows only the date).
    static func feedName(for item: RssItem, titles: [String: String]) -> String {
        if let title = titles[item.subscriptionId], !title.isEmpty { return title }
        return URL(string: item.url)?.host() ?? ""
    }
}
