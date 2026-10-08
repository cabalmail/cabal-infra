import Foundation
import Observation
import CabalmailKit

/// Backs `FeedItemDetailView`: which surface is showing (the in-feed body or
/// the publisher's article), the styling toggle, remote content, and the
/// item's state.
///
/// The initial surface, styling, and remote-content policy come from the
/// subscription's per-feed preferences (`default_open_mode`,
/// `default_styling`, `default_remote_content`), which the server stores and
/// the client applies (open Q5 of the requirements). The toolbar toggles are
/// **sticky per feed**: flipping one writes it back as that feed's default,
/// so the next item in the feed opens the same way — the settings sheet's
/// pickers and the reader's toggles are two views of the same three fields.
@Observable
@MainActor
final class FeedItemDetailViewModel {
    var item: RssItem
    /// The feed's settings row, kept current with every sticky write so a
    /// second toggle compares against what the first one stored.
    private(set) var subscription: RssSubscription?
    /// True while the publisher's page is on screen instead of the body.
    var showingArticle: Bool
    /// Reader styling (the mail reader's stylesheet for the body; Readability
    /// for the article) versus the author's own.
    var readerMode: Bool
    var remoteContentAllowed: Bool

    private let engine: RssSyncEngine?
    private let defaults: (any FeedDefaultsPersisting)?

    init(
        item: RssItem,
        subscription: RssSubscription?,
        engine: RssSyncEngine?,
        preferences: Preferences,
        defaults: (any FeedDefaultsPersisting)? = nil
    ) {
        self.item = item
        self.subscription = subscription
        self.engine = engine
        // The sync engine is the production persister; tests hand in a fake.
        self.defaults = defaults ?? engine
        let policy = FeedDetailPolicy.initial(
            for: subscription,
            hasArticleURL: URL(string: item.url) != nil,
            globalRemoteContent: preferences.loadRemoteContent
        )
        self.showingArticle = policy.showsArticle
        self.readerMode = policy.readerMode
        self.remoteContentAllowed = policy.remoteContentAllowed
    }

    /// The view's `.task` while the reader is up: follows the store, so the
    /// toolbar's read and flag state stay truthful when the item is marked
    /// elsewhere (the list's swipe or context menu, another window, another
    /// device's marks arriving by state sync), and the feed's stored
    /// defaults follow its settings sheet, which the next toggle compares
    /// against. What is on screen (article or summary, styling, remote
    /// content) stays as the reader opened it.
    func observe() async {
        guard let store = await engine?.store else { return }
        let changes = await store.changes()
        await readItem(from: store)
        await readSubscription(from: store)
        await FeedStoreChanges.follow(changes) { batch in
            if batch.cleared || batch.items.contains(item.id) || batch.feeds.contains(item.feedId) {
                await readItem(from: store)
            }
            if batch.catalog { await readSubscription(from: store) }
        }
    }

    private func readItem(from store: RssStore) async {
        guard let stored = (try? await store.item(feedId: item.feedId, sortKey: item.sortKey)) ?? nil else { return }
        item.isRead = stored.isRead
        item.isFavorite = stored.isFavorite
    }

    private func readSubscription(from store: RssStore) async {
        guard let id = subscription?.subscriptionId,
              let row = (try? await store.subscription(id: id)) ?? nil else { return }
        subscription = row
    }

    var articleURL: URL? {
        guard let url = URL(string: item.url), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
        else { return nil }
        return url
    }

    /// The per-subscription web-view storage identifier (D11): cookies and
    /// local storage set on the publisher's site stay with this feed.
    var dataStoreID: UUID? {
        subscription.flatMap { UUID(uuidString: $0.dataStoreUuid) }
    }

    func toggleArticle() {
        showingArticle.toggle()
        persistDefault(.article(showing: showingArticle))
    }

    func toggleReaderMode() {
        readerMode.toggle()
        persistDefault(.styling(readerMode: readerMode))
    }

    func toggleRemoteContent() {
        remoteContentAllowed.toggle()
        persistDefault(.remoteContent(allowed: remoteContentAllowed))
    }

    /// Writes the toggled choice back as the feed's default if it differs
    /// from what is stored — only that one field, so flipping the article
    /// view never pins remote content as a side effect. Optimistic: the
    /// in-memory row moves at once (the persister does the same for the
    /// local store, so the next item opened in this feed already honours
    /// it); the server round trip is best-effort and a failure is reconciled
    /// by the next catalog refresh. Nothing to write without a known
    /// subscription.
    private func persistDefault(_ toggle: FeedReaderToggle) {
        guard let subscription, let defaults,
              let update = FeedDetailPolicy.stickyUpdate(
                  for: subscription, toggle: toggle, hasArticleURL: articleURL != nil
              )
        else { return }
        self.subscription = subscription.applying(update)
        // The store's write tells the sidebar and the settings sheet.
        Task { _ = try? await defaults.updateSubscription(subscription, update) }
    }

    /// Optimistic: the toolbar flips at once, and the store's write tells
    /// the list and the sidebar.
    func setRead(_ isRead: Bool) async {
        item.isRead = isRead
        try? await engine?.setRead(item, isRead)
    }

    func setFavorite(_ isFavorite: Bool) async {
        item.isFavorite = isFavorite
        try? await engine?.setFavorite(item, isFavorite)
    }
}

/// Where the reader's and the list's sticky per-feed (and per-folder)
/// defaults are written. `RssSyncEngine` is the production implementation
/// (local store first, then the server); tests substitute a recorder.
protocol FeedDefaultsPersisting: Sendable {
    func updateSubscription(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws
        -> RssSubscription
    func updateFolder(_ folder: RssFolder, _ update: RssFolderUpdate) async throws -> RssFolder
}

extension RssSyncEngine: FeedDefaultsPersisting {}

/// What the reader shows first for an item, from the subscription's stored
/// preferences, and what a toggle writes back. Pure so it can be unit-tested.
enum FeedDetailPolicy {
    struct Initial: Equatable {
        var showsArticle: Bool
        var readerMode: Bool
        var remoteContentAllowed: Bool = false
    }

    static func initial(
        for subscription: RssSubscription?,
        hasArticleURL: Bool,
        globalRemoteContent: LoadRemoteContentPolicy = .off
    ) -> Initial {
        let openMode = subscription?.defaultOpenMode ?? .summary
        let styling = subscription?.defaultStyling ?? .reader
        let remote: Bool
        switch subscription?.defaultRemoteContent ?? .inherit {
        case .show: remote = true
        case .hide: remote = false
        // "Ask" is the mail reader's per-message prompt; the feed reader has
        // no prompt, so only an explicit Always shows remote content by
        // default. Same rule as before the per-feed override existed.
        case .inherit: remote = globalRemoteContent == .always
        }
        // "Article" can only be honoured when the item links somewhere.
        return Initial(
            showsArticle: openMode == .article && hasArticleURL,
            readerMode: styling == .reader,
            remoteContentAllowed: remote
        )
    }

    /// The one field a reader toggle would change on the feed's stored
    /// defaults, or nil when it already matches. The open mode is only
    /// written when the item has an article to show — without one
    /// `showsArticle` is false regardless of preference, and writing that
    /// back would silently revert an "Article" default. Remote content is
    /// written as an explicit `show` / `hide`: a toggle is a decision about
    /// this feed, which is exactly what `inherit` isn't.
    static func stickyUpdate(
        for subscription: RssSubscription,
        toggle: FeedReaderToggle,
        hasArticleURL: Bool
    ) -> RssSubscriptionUpdate? {
        var update = RssSubscriptionUpdate()
        switch toggle {
        case .article(let showing):
            guard hasArticleURL else { return nil }
            let openMode: RssOpenMode = showing ? .article : .summary
            if openMode != subscription.defaultOpenMode { update.defaultOpenMode = openMode }
        case .styling(let readerMode):
            let styling: RssStyling = readerMode ? .reader : .native
            if styling != subscription.defaultStyling { update.defaultStyling = styling }
        case .remoteContent(let allowed):
            let remote: RssRemoteContentMode = allowed ? .show : .hide
            if remote != subscription.defaultRemoteContent { update.defaultRemoteContent = remote }
        }
        return update.isEmpty ? nil : update
    }
}

/// A reader toolbar toggle and the state it left behind.
enum FeedReaderToggle: Equatable {
    case article(showing: Bool)
    case styling(readerMode: Bool)
    case remoteContent(allowed: Bool)
}
