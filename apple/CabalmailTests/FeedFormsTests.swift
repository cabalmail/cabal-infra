import XCTest
import CabalmailKit
@testable import Cabalmail

/// The pure rules behind the feed management sheets: address normalizing,
/// change detection for Save, folder picker rows, and health wording.
final class FeedFormsTests: XCTestCase {
    func testFeedURLNormalizing() {
        XCTAssertEqual(FeedFormRules.normalizedFeedURL(" example.com/feed "), "https://example.com/feed")
        XCTAssertEqual(FeedFormRules.normalizedFeedURL("HTTP://example.com/"), "HTTP://example.com/")
        XCTAssertEqual(FeedFormRules.normalizedFeedURL("https://blog.rust-lang.org/feed.xml"),
                       "https://blog.rust-lang.org/feed.xml")
        XCTAssertNil(FeedFormRules.normalizedFeedURL(""))
        XCTAssertNil(FeedFormRules.normalizedFeedURL("not a url"))
        XCTAssertNil(FeedFormRules.normalizedFeedURL("localhost"))
    }

    func testSettingsFormSendsOnlyWhatChanged() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", folderId: "root-ish", customTitle: "",
                                  orderingMode: .newestFirst, defaultOpenMode: .summary, defaultStyling: .reader)
        let form = FeedSubscriptionSettingsForm()
        form.load(from: sub)
        XCTAssertNil(form.update(against: sub))

        form.customTitle = "  Mine "
        form.defaultOpenMode = .article
        let update = form.update(against: sub)
        XCTAssertEqual(update?.customTitle, "Mine")
        XCTAssertEqual(update?.defaultOpenMode, .article)
        XCTAssertNil(update?.folderId)
        XCTAssertNil(update?.orderingMode)
        XCTAssertNil(update?.defaultStyling)
    }

    func testFolderFormEditDetectsRenameAndMove() {
        let folder = RssFolder(folderId: "a", parentFolderId: "", name: "Tech")
        let form = FeedFolderForm()
        form.reset(editing: folder, parentId: nil)
        XCTAssertFalse(form.canSave)
        XCTAssertNil(form.folderUpdate)

        form.parentId = "b"
        XCTAssertTrue(form.canSave)
        XCTAssertEqual(form.folderUpdate?.parentFolderId, "b")
        XCTAssertNil(form.folderUpdate?.name)

        form.name = "Technology"
        XCTAssertEqual(form.folderUpdate?.name, "Technology")

        form.reset(editing: nil, parentId: "b")
        XCTAssertFalse(form.canSave, "a new folder needs a name")
        form.name = "News"
        XCTAssertTrue(form.canSave)
        XCTAssertNil(form.folderUpdate, "creating is not an update")
    }

    func testFolderChoicesWalkTheTreeAndExcludeASubtree() {
        let folders = [
            RssFolder(folderId: "b", parentFolderId: "", name: "Work", displayOrder: 1),
            RssFolder(folderId: "a", parentFolderId: "", name: "Tech", displayOrder: 0),
            RssFolder(folderId: "a1", parentFolderId: "a", name: "Rust"),
            RssFolder(folderId: "a1x", parentFolderId: "a1", name: "Nightly"),
        ]
        let all = FeedFolderChoices.choices(folders: folders)
        XCTAssertEqual(all.map(\.label), ["Tech", "Rust", "Nightly", "Work"])
        XCTAssertEqual(all.map(\.depth), [0, 1, 2, 0])

        let withoutRust = FeedFolderChoices.choices(folders: folders, excluding: "a1")
        XCTAssertEqual(withoutRust.map(\.label), ["Tech", "Work"], "a folder can't move under itself")
    }

    func testHealthWording() {
        var feed = RssFeedSummary(feedId: "f", canonicalUrl: "https://example.com/feed", title: "Example")
        XCTAssertEqual(FeedHealthText.status(feed), "Not fetched yet")
        XCTAssertEqual(FeedHealthText.lastFetched(feed), "Never")
        XCTAssertEqual(FeedHealthText.cadence(feed), "Not scheduled yet")

        feed.lastFetchedAt = "2026-09-10T00:00:00+00:00"
        feed.cadenceMinutes = 90
        XCTAssertEqual(FeedHealthText.status(feed), "OK")
        XCTAssertEqual(FeedHealthText.cadence(feed), "About every hour")

        feed.consecutiveFailureCount = 3
        feed.lastStatusCode = 503
        XCTAssertEqual(FeedHealthText.status(feed), "Failing (3 in a row, last status 503)")

        feed.deadLettered = true
        XCTAssertEqual(FeedHealthText.status(feed), "Stopped: the fetcher gave up on this feed")
    }

    func testOpmlSummaryListsFailures() throws {
        let json = """
        {"created": 1, "existing": 0, "folders_created": 0,
         "failed": [{"url": "https://a.example/feed", "code": "not_https", "Error": "no https"}]}
        """
        let result = try JSONDecoder().decode(RssOpmlImportResult.self, from: Data(json.utf8))
        let text = FeedOpmlSummary.text(for: result)
        XCTAssertTrue(text.hasPrefix("1 new feed."))
        XCTAssertTrue(text.contains("1 entry could not be added"))
        XCTAssertTrue(text.contains("https://a.example/feed"))
    }
}
