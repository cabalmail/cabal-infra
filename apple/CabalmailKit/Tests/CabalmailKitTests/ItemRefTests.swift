import XCTest
@testable import CabalmailKit

/// `ItemRef`, the one identity for a mail message or a feed item.
final class ItemRefTests: XCTestCase {
    func testAMessageIsItsMessageRef() {
        let ref = ItemRef.mail(MessageRef(folder: "INBOX", uid: 9))

        XCTAssertEqual(ref, .mail(MessageRef(folder: "INBOX", uid: 9)))
        XCTAssertNotEqual(ref, .mail(MessageRef(folder: "Sent", uid: 9)), "one UID in two folders is two messages")
        XCTAssertEqual(ref.message, MessageRef(folder: "INBOX", uid: 9))
    }

    /// A message's hints take no part in its identity (`MessageRef`), so they
    /// take none here: a search row and a folder row for one message are one
    /// row of a mixed list.
    func testAMessagesHintsTakeNoPartInIdentity() {
        let fromSearch = ItemRef.mail(MessageRef(folder: "INBOX", uid: 9))
        let fromFolder = ItemRef.mail(MessageRef(folder: "INBOX", uid: 9, uidValidity: 77, messageId: "<m@x>"))

        XCTAssertEqual(fromSearch, fromFolder)
        XCTAssertEqual(Set([fromSearch, fromFolder]).count, 1)
    }

    func testAFeedItemIsItsFeedAndSortKey() {
        let ref = ItemRef.feed(feedID: "f", sortKey: "2026-11-21#a")

        XCTAssertEqual(ref, .feed(feedID: "f", sortKey: "2026-11-21#a"))
        XCTAssertNotEqual(ref, .feed(feedID: "g", sortKey: "2026-11-21#a"), "a sort key is unique within its feed only")
        XCTAssertNotEqual(ref, .feed(feedID: "f", sortKey: "2026-11-21#b"))
        XCTAssertNil(ref.message)
    }

    /// The two media never collide, whatever their fields hold.
    func testAMessageIsNeverAFeedItem() {
        let message = ItemRef.mail(MessageRef(folder: "f", uid: 1))
        let item = ItemRef.feed(feedID: "f", sortKey: "1")

        XCTAssertNotEqual(message, item)
        XCTAssertEqual(Set([message, item]).count, 2)
    }

    /// The subscription is not part of a feed item's identity: one feed
    /// reached through two subscriptions holds the same item.
    func testAFeedItemNamesItselfByItsFeedNotItsSubscription() {
        let one = RssItem(feedId: "f", subscriptionId: "s1", itemId: "i", sortKey: "k")
        let two = RssItem(feedId: "f", subscriptionId: "s2", itemId: "i", sortKey: "k")

        XCTAssertEqual(one.ref, .feed(feedID: "f", sortKey: "k"))
        XCTAssertEqual(one.ref, two.ref)
    }

    func testEachCaseRoundTripsThroughItsCoding() throws {
        let refs: [ItemRef] = [
            .mail(MessageRef(folder: "Lists/swift", uid: 812, uidValidity: 5, messageId: "<m@x>")),
            .feed(feedID: "f", sortKey: "2026-11-21#a"),
        ]

        let decoded = try JSONDecoder().decode([ItemRef].self, from: JSONEncoder().encode(refs))

        XCTAssertEqual(decoded, refs)
        XCTAssertEqual(decoded.first?.message?.messageId, "<m@x>", "the hints ride along")
        XCTAssertEqual(decoded.first?.message?.uidValidity, 5)
    }
}
