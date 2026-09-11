import XCTest
import CabalmailKit
@testable import Cabalmail

/// The reader's toolbar toggles are sticky per feed: a flip writes the
/// feed's default through `FeedDefaultsPersisting`, so the next item in the
/// feed opens the same way. Exercised through the view model with a
/// recording persister.
@MainActor
final class FeedItemDetailStickyDefaultsTests: XCTestCase {
    private final class RecordingPersister: FeedDefaultsPersisting, @unchecked Sendable {
        private(set) var calls: [(RssSubscription, RssSubscriptionUpdate)] = []
        var failing = false

        func updateSubscription(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws
            -> RssSubscription {
            calls.append((subscription, update))
            if failing { throw CabalmailError.transport("offline") }
            return subscription.applying(update)
        }
    }

    private func makeModel(
        subscription: RssSubscription?,
        url: String = "https://example.com/post",
        persister: RecordingPersister,
        remotePolicy: LoadRemoteContentPolicy = .off
    ) -> FeedItemDetailViewModel {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.loadRemoteContent = remotePolicy
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k", url: url,
                           summaryHtml: "<p>hi</p>")
        return FeedItemDetailViewModel(item: item, subscription: subscription, engine: nil,
                                       preferences: preferences, defaults: persister, bus: FeedStateBus())
    }

    /// Waits for the write-through task the toggle spawned.
    private func settle(_ persister: RecordingPersister, expecting count: Int) async {
        for _ in 0..<200 where persister.calls.count < count {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testInitialStateComesFromTheFeedDefaults() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: .article,
                                  defaultStyling: .native, defaultRemoteContent: .show)
        let model = makeModel(subscription: sub, persister: RecordingPersister())
        XCTAssertTrue(model.showingArticle)
        XCTAssertFalse(model.readerMode)
        XCTAssertTrue(model.remoteContentAllowed)
    }

    func testTogglingArticleWritesTheOpenModeBack() async {
        let persister = RecordingPersister()
        let sub = RssSubscription(subscriptionId: "s", feedId: "f")
        let model = makeModel(subscription: sub, persister: persister)
        model.toggleArticle()
        await settle(persister, expecting: 1)
        XCTAssertEqual(persister.calls.count, 1)
        XCTAssertEqual(persister.calls[0].1.defaultOpenMode, .article)
        XCTAssertNil(persister.calls[0].1.defaultStyling)
        XCTAssertNil(persister.calls[0].1.defaultRemoteContent)
        XCTAssertEqual(model.subscription?.defaultOpenMode, .article, "the in-memory row moves at once")
    }

    func testSecondToggleComparesAgainstTheFirstWrite() async {
        let persister = RecordingPersister()
        let model = makeModel(subscription: RssSubscription(subscriptionId: "s", feedId: "f"), persister: persister)
        model.toggleReaderMode()
        await settle(persister, expecting: 1)
        model.toggleReaderMode()
        await settle(persister, expecting: 2)
        XCTAssertEqual(persister.calls.map { $0.1.defaultStyling }, [.native, .reader])
    }

    func testRemoteContentToggleWritesAnExplicitMode() async {
        let persister = RecordingPersister()
        let model = makeModel(subscription: RssSubscription(subscriptionId: "s", feedId: "f"), persister: persister,
                              remotePolicy: .always)
        XCTAssertTrue(model.remoteContentAllowed, "inherit + Always shows remote content")
        model.toggleRemoteContent()
        await settle(persister, expecting: 1)
        XCTAssertEqual(persister.calls.first?.1.defaultRemoteContent, .hide)
        XCTAssertFalse(model.remoteContentAllowed)
    }

    func testNothingIsWrittenWithoutASubscription() async {
        let persister = RecordingPersister()
        let model = makeModel(subscription: nil, persister: persister)
        model.toggleArticle()
        model.toggleReaderMode()
        model.toggleRemoteContent()
        await settle(persister, expecting: 1)
        XCTAssertTrue(persister.calls.isEmpty)
        XCTAssertTrue(model.showingArticle, "the toggles still work for this item")
    }

    func testAPersistFailureLeavesTheReaderStateAlone() async {
        let persister = RecordingPersister()
        persister.failing = true
        let model = makeModel(subscription: RssSubscription(subscriptionId: "s", feedId: "f"), persister: persister)
        model.toggleReaderMode()
        await settle(persister, expecting: 1)
        XCTAssertEqual(persister.calls.count, 1)
        XCTAssertFalse(model.readerMode)
        XCTAssertEqual(model.subscription?.defaultStyling, .native)
    }

    func testOpenModeIsNotWrittenForAnItemWithoutALink() async {
        let persister = RecordingPersister()
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultOpenMode: .article)
        let model = makeModel(subscription: sub, url: "", persister: persister)
        XCTAssertFalse(model.showingArticle, "no link, so the body shows despite the Article default")
        model.toggleReaderMode()
        await settle(persister, expecting: 1)
        XCTAssertEqual(persister.calls.count, 1)
        XCTAssertNil(persister.calls[0].1.defaultOpenMode)
        XCTAssertEqual(persister.calls[0].1.defaultStyling, .native)
    }
}
