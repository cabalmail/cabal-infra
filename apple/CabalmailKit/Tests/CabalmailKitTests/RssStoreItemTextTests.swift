import XCTest
@testable import CabalmailKit

/// `RssStore.newestItemText`: a feed's newest items as a search index sees
/// them, read from the text the store keeps and never from the HTML.
final class RssStoreItemTextTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-item-text-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ key: String, feed: String = "f1", content: String = "") -> RssItem {
        RssItem(
            feedId: feed, itemId: key, sortKey: key, title: "Title \(key)", author: "Ada",
            publishedAt: "2026-01-02T00:00:00+00:00", contentHtml: content
        )
    }

    func testItGivesOneFeedsNewestItemsNewestFirst() async throws {
        try await store.upsertItems([item("a"), item("c"), item("b"), item("z", feed: "f2")])

        let texts = try await store.newestItemText(feedId: "f1", limit: 2, maxTextLength: 100)

        XCTAssertEqual(texts.map(\.sortKey), ["c", "b"])
        XCTAssertEqual(texts.map(\.feedId), ["f1", "f1"])
    }

    func testItCarriesWhatTheItemIsCalledAndItsProse() async throws {
        let stored = item("a", content: "<p>Body <b>text</b></p>")
        try await store.upsertItems([stored])

        let texts = try await store.newestItemText(feedId: "f1", limit: 10, maxTextLength: 100)

        XCTAssertEqual(texts, [RssItemText(item: stored)])
        XCTAssertEqual(texts.first?.title, "Title a")
        XCTAssertEqual(texts.first?.author, "Ada")
        XCTAssertEqual(texts.first?.publishedAt, "2026-01-02T00:00:00+00:00")
        XCTAssertEqual(texts.first?.text, "Body text")
    }

    /// The cut is made in the read, so a long article's whole text is never
    /// loaded for an index that takes only its start.
    func testItCutsTheTextInTheRead() async throws {
        try await store.upsertItems([item("a", content: "<p>" + String(repeating: "word ", count: 100) + "</p>")])

        let texts = try await store.newestItemText(feedId: "f1", limit: 10, maxTextLength: 12)

        XCTAssertEqual(texts.first?.text, "word word wo")
    }

    func testAFeedWithNoItemsGivesNone() async throws {
        let texts = try await store.newestItemText(feedId: "none", limit: 10, maxTextLength: 100)
        XCTAssertEqual(texts, [])
    }
}
