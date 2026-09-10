import Foundation
import Observation
import CabalmailKit

/// Backs `FeedItemListView`: one page of items for a scope from the local
/// store, the all / unread / favorite filter, the subscription's ordering,
/// per-feed search, and the optimistic read / favorite mutations.
///
/// Everything the list shows comes from `RssStore`; the network only runs
/// in `sync()` (fresh items) and `loadOlder()` (history), both of which
/// re-read the store afterwards.
@Observable
@MainActor
final class FeedItemListViewModel {
    let scope: RssItemScope
    var items: [RssItem] = []
    var filter: RssItemFilter = .all {
        didSet { Task { await reload() } }
    }
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

    private let client: CabalmailClient
    private let preferences: Preferences
    private let bus: FeedStateBus
    private let pageSize = 100
    private var loaded = 0

    /// The single subscription this list shows, when it shows exactly one;
    /// search, load-older, and the ordering preference only make sense then.
    let subscription: RssSubscription?

    init(scope: RssItemScope, subscription: RssSubscription?, client: CabalmailClient, preferences: Preferences,
         bus: FeedStateBus = .shared) {
        self.scope = scope
        self.subscription = subscription
        self.client = client
        self.preferences = preferences
        self.bus = bus
        self.ordering = subscription?.orderingMode ?? .newestFirst
        bus.subscribe(self) { [weak self] change in self?.apply(change) }
    }

    /// A state change made elsewhere (the reader's toolbar, another list):
    /// patch the row in place so the dot and star agree without a reload.
    /// Rows stay put even when they no longer match the filter; the next
    /// reload settles that, the same as the list's own swipe actions.
    func apply(_ change: RssItem?) {
        guard let change else { return }
        replace(change) {
            $0.isRead = change.isRead
            $0.isFavorite = change.isFavorite
        }
    }

    var canSearch: Bool { subscription != nil }
    var canLoadOlder: Bool { subscription != nil && !olderExhausted }

    /// First page from the store.
    func reload() async {
        guard let store = client.rssStore else { return }
        do {
            if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, let subscription {
                items = try await store.search(feedId: subscription.feedId, query: searchQuery)
                hasMoreLocal = false
            } else {
                items = try await store.items(.init(scope: scope, filter: filter, ordering: ordering,
                                                    limit: pageSize, offset: 0))
                hasMoreLocal = items.count == pageSize
            }
            loaded = items.count
            await refreshPendingMarks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Next page from the store (scrolling).
    func loadMore() async {
        guard hasMoreLocal, let store = client.rssStore, searchQuery.isEmpty else { return }
        do {
            let page = try await store.items(.init(scope: scope, filter: filter, ordering: ordering,
                                                   limit: pageSize, offset: loaded))
            items += page
            loaded += page.count
            hasMoreLocal = page.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fresh items from the server for the feeds in scope, then a reload.
    func sync() async {
        guard !isSyncing, let engine = client.rssSync, let store = client.rssStore else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let subs = try await store.subscriptions()
            let feedIds = Set(try await store.feedIds(in: scope))
            for sub in subs where feedIds.contains(sub.feedId) {
                try await engine.syncItems(for: sub)
            }
            try? await engine.drainPending()
            errorMessage = nil
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
        await reload()
        bus.post()
    }

    /// Older history for a single feed, then a reload.
    func loadOlder() async {
        guard let subscription, let engine = client.rssSync, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let received = try await engine.loadOlder(for: subscription)
            olderExhausted = received == 0
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
        await reload()
        bus.post()
    }

    // MARK: - Mutations (optimistic; the engine queues and pushes)

    func setRead(_ item: RssItem, _ isRead: Bool) async {
        guard let engine = client.rssSync else { return }
        var changed = item
        changed.isRead = isRead
        replace(item) { $0.isRead = isRead }
        try? await engine.setRead(item, isRead)
        bus.post(changed)
        await refreshPendingMarks()
    }

    func setFavorite(_ item: RssItem, _ isFavorite: Bool) async {
        guard let engine = client.rssSync else { return }
        var changed = item
        changed.isFavorite = isFavorite
        replace(item) { $0.isFavorite = isFavorite }
        try? await engine.setFavorite(item, isFavorite)
        bus.post(changed)
        await refreshPendingMarks()
    }

    /// Applies the user's mark-as-read preference when an item opens.
    func didOpen(_ item: RssItem) async {
        guard preferences.rssMarkAsRead == .onOpen, !item.isRead else { return }
        await setRead(item, true)
    }

    func markAllRead() async {
        guard let engine = client.rssSync, let store = client.rssStore else { return }
        let feedIds = Set((try? await store.feedIds(in: scope)) ?? [])
        let subs = ((try? await store.subscriptions()) ?? []).filter { feedIds.contains($0.feedId) }
        for sub in subs {
            try? await engine.markAllRead(subscriptionId: sub.subscriptionId)
        }
        await reload()
        bus.post()
    }

    private func replace(_ item: RssItem, _ change: (inout RssItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        change(&items[index])
    }

    private func refreshPendingMarks() async {
        guard let store = client.rssStore else { return }
        var pending: Set<String> = []
        for item in items where (try? await store.hasPending(feedId: item.feedId, sortKey: item.sortKey)) == true {
            pending.insert(item.id)
        }
        pendingIds = pending
    }
}
