import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the search scope's tests build on: the window's search model over
/// a fake mail client, a real feed store with two subscribed feeds, and the
/// search place beside the model, as the navigator holds them.
@MainActor
final class SearchFixture {
    let directory: URL
    let store: RssStore
    let rss = FakeRssClient()
    let imap = FakeImapClient()
    let preferences: Preferences
    let model: MessageListViewModel
    let place = SearchPlace()

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        model = MessageListViewModel(
            scope: .search, client: try TestFixtures.makeClient(imap: imap), preferences: preferences,
            mailStore: AppState().mailStore
        )
        let catalog = RssCatalog(folders: [], subscriptions: [
            RssSubscription(subscriptionId: "s1", feedId: "f1", customTitle: "Harbour News", defaultFilter: .all),
            RssSubscription(subscriptionId: "s2", feedId: "f2", customTitle: "Tide Tables", defaultFilter: .all),
        ])
        _ = try await store.replaceCatalog(catalog)
        await rss.set(catalog: catalog)
        place.attach(model)
        place.feedStoreOverride = FlaggedFeedStore(store: store, engine: RssSyncEngine(client: rss, store: store))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    var feeds: FlaggedFeedStore { place.feedStore }

    // MARK: Feed items

    /// Puts an article in the store, published at noon on a day of March.
    func addArticle(
        _ key: String, day: Int, title: String, feed: String = "f1", favorite: Bool = false
    ) async throws {
        let published = String(format: "2026-03-%02dT12:00:00Z", day)
        try await store.upsertItems([
            RssItem(feedId: feed, subscriptionId: feed == "f1" ? "s1" : "s2", itemId: key,
                    sortKey: "\(published)#\(key)", title: title, publishedAt: published, isFavorite: favorite),
        ])
    }

    /// `count` articles that all match "ferry", the newest first by key.
    func addFerryArticles(_ count: Int) async throws {
        for index in 1...count {
            try await addArticle(String(format: "a%02d", index), day: min(index, 28), title: "Ferry \(index)")
        }
    }

    var articleKeys: [String] { place.feeds.rows.map(\.itemId) }

    // MARK: Mail

    /// The server's answer to a search: `uids` in INBOX, of `total` in all.
    static func mailResult(_ uids: [UInt32], total: Int? = nil, truncated: Bool = false) -> SearchResult {
        SearchResult(
            envelopes: uids.map { SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: $0), folder: "INBOX") },
            totalEstimate: total ?? uids.count, nextCursor: nil, foldersSearched: ["INBOX"], truncated: truncated
        )
    }

    /// The terms the mail client was asked to search for, in order.
    func mailTerms() async -> [String?] {
        await imap.searchCalls.map(\.text)
    }

    /// The field's Return on `term`.
    func submit(_ term: String) async {
        model.searchQuery = term
        await place.submit()
    }

    func sections(isOffline: Bool = false) -> SearchSections {
        SearchSections(model: model, place: place, isOffline: isOffline)
    }
}
