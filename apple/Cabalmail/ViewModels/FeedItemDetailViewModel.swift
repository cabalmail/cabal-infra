import Foundation
import Observation
import CabalmailKit

/// Backs `FeedItemDetailView`: which surface is showing (the in-feed body or
/// the publisher's article), the styling toggle, and the item's state.
///
/// The initial surface and styling come from the subscription's per-feed
/// preferences (`default_open_mode`, `default_styling`), which the server
/// stores and the client applies (open Q5 of the requirements).
@Observable
@MainActor
final class FeedItemDetailViewModel {
    var item: RssItem
    let subscription: RssSubscription?
    /// True while the publisher's page is on screen instead of the body.
    var showingArticle: Bool
    /// Reader styling (the mail reader's stylesheet for the body; Readability
    /// for the article) versus the author's own.
    var readerMode: Bool
    var remoteContentAllowed: Bool

    private let engine: RssSyncEngine?

    init(item: RssItem, subscription: RssSubscription?, engine: RssSyncEngine?, preferences: Preferences) {
        self.item = item
        self.subscription = subscription
        self.engine = engine
        let policy = FeedDetailPolicy.initial(for: subscription, hasArticleURL: URL(string: item.url) != nil)
        self.showingArticle = policy.showsArticle
        self.readerMode = policy.readerMode
        self.remoteContentAllowed = preferences.loadRemoteContent == .always
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

    func toggleArticle() { showingArticle.toggle() }
    func toggleReaderMode() { readerMode.toggle() }
    func toggleRemoteContent() { remoteContentAllowed.toggle() }

    func setRead(_ isRead: Bool) async {
        item.isRead = isRead
        try? await engine?.setRead(item, isRead)
    }

    func setFavorite(_ isFavorite: Bool) async {
        item.isFavorite = isFavorite
        try? await engine?.setFavorite(item, isFavorite)
    }
}

/// What the reader shows first for an item, from the subscription's stored
/// preferences. Pure so it can be unit-tested.
enum FeedDetailPolicy {
    struct Initial: Equatable {
        var showsArticle: Bool
        var readerMode: Bool
    }

    static func initial(for subscription: RssSubscription?, hasArticleURL: Bool) -> Initial {
        let openMode = subscription?.defaultOpenMode ?? .summary
        let styling = subscription?.defaultStyling ?? .reader
        // "Article" can only be honoured when the item links somewhere.
        return Initial(showsArticle: openMode == .article && hasArticleURL, readerMode: styling == .reader)
    }
}
