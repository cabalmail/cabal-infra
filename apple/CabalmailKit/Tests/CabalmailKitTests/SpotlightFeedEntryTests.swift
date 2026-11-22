import XCTest
import CoreSpotlight
import UniformTypeIdentifiers
@testable import CabalmailKit

/// A feed item's Spotlight entry as a value (`SpotlightFeedItemRef`,
/// `SpotlightFeedEntry`, `RssItemText`): its identifier and domain, and what
/// it says of the item. How entries reach the index is in
/// `SpotlightFeedIndexerTests`.
final class SpotlightFeedEntryTests: XCTestCase {
    // MARK: - Identifier

    func testTheIdentifierRoundTrips() {
        for (feed, key) in [
            ("f1", "2026-01-02T00:00:00+00:00#i1"), ("feed|with|pipes", "key#with|pipe"),
            ("fééd", "clé 日本"), ("a.b.c", "x/y?z=1&w=2"),
        ] {
            let ref = SpotlightFeedItemRef(feedID: feed, sortKey: key)
            XCTAssertEqual(SpotlightFeedItemRef(string: ref.stringValue), ref, "\(feed) \(key)")
            XCTAssertEqual(ref.itemRef, .feed(feedID: feed, sortKey: key))
        }
    }

    func testTheIdentifierIsTheFormatResultsAlreadyCarry() {
        let ref = SpotlightFeedItemRef(feedID: "f1", sortKey: "k#1")
        XCTAssertEqual(ref.stringValue, "cabalmail-feed|v1|ZjE|ayMx")
        XCTAssertEqual(SpotlightFeedItemRef(string: "cabalmail-feed|v1|ZjE|ayMx"), ref)
    }

    func testAnIdentifierThatIsNotAFeedItemsIsRefused() {
        let message = SpotlightMessageRef(folder: "INBOX", uid: 42)
        for other in [
            "", "com.example.other-app-item", message.stringValue, "cabalmail-feed|v0|ZjE|ayMx",
            "cabalmail-msg|v1|ZjE|ayMx", "someone-elses|v1|ZjE|ayMx",
            "cabalmail-feed|v1|ZjE", "cabalmail-feed|v1||ayMx", "cabalmail-feed|v1|ZjE|", "cabalmail-feed|v1|%%%|ayMx",
        ] {
            XCTAssertNil(SpotlightFeedItemRef(string: other), other)
        }
        // And the other way: a message's parser does not take a feed item's.
        XCTAssertNil(SpotlightMessageRef(string: SpotlightFeedItemRef(feedID: "f1", sortKey: "k").stringValue))
    }

    /// One domain per feed, with no `.` (Core Spotlight's hierarchy
    /// separator) whatever the feed id holds, so deleting one feed's domain
    /// deletes that feed's items and nothing else.
    func testEachFeedHasADomainOfItsOwnWithNoHierarchy() {
        let first = SpotlightFeedItemRef.domainIdentifier(feedID: "feeds.example/a.xml")
        let second = SpotlightFeedItemRef.domainIdentifier(feedID: "feeds.example/b.xml")
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("."))
        XCTAssertTrue(first.hasPrefix("cabalmail-feed-"))
        let text = RssItemText(feedId: "feeds.example/a.xml", sortKey: "k")
        let entry = SpotlightFeedEntry(text: text, maxTextLength: 10)
        XCTAssertEqual(entry.domainIdentifier, first)
    }

    // MARK: - Entry

    func testAnEntrySaysWhatTheItemIs() {
        let text = RssItemText(
            feedId: "f1", sortKey: "k", title: "  Swift 7 ships  ", author: " Ada ",
            publishedAt: "2026-01-02T03:04:05+00:00", text: "The   release\nnotes are long."
        )
        let entry = SpotlightFeedEntry(text: text, maxTextLength: 1000)

        XCTAssertEqual(entry.uniqueIdentifier, SpotlightFeedItemRef(feedID: "f1", sortKey: "k").stringValue)
        XCTAssertEqual(entry.title, "Swift 7 ships")
        XCTAssertEqual(entry.authorNames, ["Ada"])
        XCTAssertEqual(entry.date, Date(timeIntervalSince1970: 1_767_323_045))
        XCTAssertEqual(entry.textContent, "The   release\nnotes are long.")
        XCTAssertEqual(entry.contentDescription, "The release notes are long.")
    }

    func testAnEntryWithNothingToSayStillHasAName() {
        let entry = SpotlightFeedEntry(text: RssItemText(feedId: "f1", sortKey: "k"), maxTextLength: 1000)

        XCTAssertEqual(entry.title, "Untitled")
        XCTAssertEqual(entry.authorNames, [])
        XCTAssertNil(entry.date)
        XCTAssertNil(entry.textContent)
        XCTAssertNil(entry.contentDescription)
    }

    func testAnEntryWithNoTextFallsBackToItsAuthorAndReadsAFractionalDate() {
        let text = RssItemText(feedId: "f1", sortKey: "k", author: "Ada", publishedAt: "2026-01-02T03:04:05.250Z")
        let entry = SpotlightFeedEntry(text: text, maxTextLength: 1000)

        XCTAssertEqual(entry.contentDescription, "Ada")
        XCTAssertEqual(entry.date, Date(timeIntervalSince1970: 1_767_323_045.25))
    }

    func testAnEntrysTextIsCut() {
        let text = RssItemText(feedId: "f1", sortKey: "k", text: String(repeating: "a", count: 50))
        XCTAssertEqual(SpotlightFeedEntry(text: text, maxTextLength: 20).textContent?.count, 20)
    }

    /// An item in hand and the same item read back from the store give one
    /// text: the content when there is any, else the summary, with no markup.
    func testAnItemsTextIsItsProse() {
        let withContent = RssItem(
            feedId: "f1", itemId: "a", sortKey: "a", title: "T", author: "Ada", publishedAt: "p",
            summaryHtml: "<p>Summary</p>", contentHtml: "<h1>Head</h1><p>Body <b>text</b></p><script>x()</script>"
        )
        let summaryOnly = RssItem(feedId: "f1", itemId: "b", sortKey: "b", summaryHtml: "<p>Only a summary</p>")

        let text = RssItemText(item: withContent)
        XCTAssertEqual(text.feedId, "f1")
        XCTAssertEqual(text.sortKey, "a")
        XCTAssertEqual(text.title, "T")
        XCTAssertEqual(text.author, "Ada")
        XCTAssertEqual(text.publishedAt, "p")
        XCTAssertTrue(text.text.contains("Body text"), text.text)
        XCTAssertFalse(text.text.contains("<"), text.text)
        XCTAssertFalse(text.text.contains("x()"), text.text)
        XCTAssertFalse(text.text.contains("Summary"), text.text)
        XCTAssertEqual(RssItemText(item: summaryOnly).text, "Only a summary")
    }

    // MARK: - CSSearchableItem mapping

    /// As for a message (`SpotlightIndexerTests`): the content type must not
    /// be one macOS hands to another app, and iOS shows an item only when
    /// its attribute set has a `displayName`.
    func testTheSearchableItemComesBackToThisApp() throws {
        let text = RssItemText(
            feedId: "f1", sortKey: "k", title: "Swift 7 ships", author: "Ada",
            publishedAt: "2026-01-02T03:04:05+00:00", text: "The release notes."
        )
        let entry = SpotlightFeedEntry(text: text, maxTextLength: 1000)

        let item = entry.searchableItem()

        XCTAssertEqual(item.uniqueIdentifier, entry.uniqueIdentifier)
        XCTAssertEqual(item.domainIdentifier, entry.domainIdentifier)
        XCTAssertEqual(item.attributeSet.contentType, UTType.text.identifier)
        XCTAssertEqual(item.attributeSet.displayName, "Swift 7 ships")
        XCTAssertEqual(item.attributeSet.title, "Swift 7 ships")
        XCTAssertEqual(item.attributeSet.authorNames, ["Ada"])
        XCTAssertEqual(item.attributeSet.textContent, "The release notes.")
        XCTAssertEqual(item.attributeSet.contentDescription, "The release notes.")
        XCTAssertEqual(item.attributeSet.contentCreationDate, Date(timeIntervalSince1970: 1_767_323_045))
        // A result opens the item in the app, not its page in a browser.
        XCTAssertNil(item.attributeSet.contentURL)
        XCTAssertNil(item.attributeSet.url)
        XCTAssertNotEqual(item.expirationDate, .distantFuture)
    }
}
