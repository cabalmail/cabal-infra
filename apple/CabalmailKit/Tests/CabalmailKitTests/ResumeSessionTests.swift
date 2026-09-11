import XCTest
@testable import CabalmailKit

/// The local resume layer (`docs/1.x/resume-session-plan.md`): the session
/// record, the reading-position cache, and their `UserDefaults` store.
final class ResumeSessionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ResumeSessionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Scope token

    func testScopeTokenRoundTrips() {
        for scope in [RssItemScope.all, .subscription("sub-1"), .folder("fold-9")] {
            XCTAssertEqual(RssItemScope(token: scope.token), scope)
        }
        XCTAssertEqual(RssItemScope.all.token, "all")
        XCTAssertEqual(RssItemScope.subscription("s").token, "sub:s")
        XCTAssertEqual(RssItemScope.folder("f").token, "folder:f")
    }

    func testScopeTokenRejectsMalformedValues() {
        XCTAssertNil(RssItemScope(token: ""))
        XCTAssertNil(RssItemScope(token: "sub:"))
        XCTAssertNil(RssItemScope(token: "nope:x"))
        XCTAssertNil(RssItemScope(token: "ALL"))
    }

    func testScopeCodableUsesToken() throws {
        let data = try JSONEncoder().encode([RssItemScope.folder("f1")])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"folder:f1\"]")
        let decoded = try JSONDecoder().decode([RssItemScope].self, from: data)
        XCTAssertEqual(decoded, [.folder("f1")])
        XCTAssertThrowsError(try JSONDecoder().decode([RssItemScope].self, from: Data("[\"bogus\"]".utf8)))
    }

    // MARK: Session record

    func testSessionRoundTripsThroughStore() {
        let store = ResumeSessionStore(defaults: defaults)
        XCTAssertNil(store.loadSession())
        let session = ResumeSession(
            section: .feeds,
            folder: "Lists.Cabal",
            uid: 42,
            messageID: "<abc@x>",
            feedScope: .subscription("sub-1"),
            feedItemFeedID: "feed-1",
            feedItemSortKey: "2026-09-11T00:00:00Z#item",
            savedAt: Date(timeIntervalSince1970: 1_757_548_800)
        )
        store.saveSession(session)
        XCTAssertEqual(store.loadSession(), session)
        XCTAssertEqual(ResumeSessionStore.storedSection(defaults: defaults), .feeds)
    }

    func testSessionClearHelpers() {
        var session = ResumeSession(
            section: .feeds, folder: "INBOX", uid: 1, messageID: "<m>",
            feedScope: .all, feedItemFeedID: "f", feedItemSortKey: "k"
        )
        XCTAssertTrue(session.hasMessage)
        XCTAssertTrue(session.hasFeedItem)
        session.clearFeedItem()
        XCTAssertFalse(session.hasFeedItem)
        XCTAssertEqual(session.feedScope, .all)
        session.clearMessage()
        XCTAssertFalse(session.hasMessage)
        XCTAssertEqual(session.folder, "INBOX")
    }

    // MARK: Position cache

    func testPositionCacheEvictsOldestPastCapacity() {
        var cache = ReadingPositionCache(capacity: 3)
        cache.set(ReadingPosition(anchor: "i1|0"), for: "a")
        cache.set(ReadingPosition(anchor: "i2|0"), for: "b")
        cache.set(ReadingPosition(anchor: "i3|0"), for: "c")
        // Refreshing `a` makes `b` the oldest.
        cache.set(ReadingPosition(anchor: "i1|5"), for: "a")
        cache.set(ReadingPosition(anchor: "i4|0"), for: "d")
        XCTAssertNil(cache.position(for: "b"))
        XCTAssertEqual(cache.position(for: "a")?.anchor, "i1|5")
        XCTAssertEqual(cache.position(for: "c")?.anchor, "i3|0")
        XCTAssertEqual(cache.position(for: "d")?.anchor, "i4|0")
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.order, ["c", "a", "d"])
    }

    func testPositionCacheRemove() {
        var cache = ReadingPositionCache(capacity: 5)
        cache.set(ReadingPosition(offset: 120), for: "x")
        cache.remove("x")
        cache.remove("never-there")
        XCTAssertNil(cache.position(for: "x"))
        XCTAssertEqual(cache.order, [])
    }

    func testPositionCacheRoundTripsThroughStore() {
        let store = ResumeSessionStore(defaults: defaults)
        XCTAssertEqual(store.loadPositions().count, 0)
        var cache = ReadingPositionCache(capacity: 10)
        cache.set(ReadingPosition(anchor: "i2.0.5|-12"), for: ReadingPositionKey.feed(itemID: "feed#key"))
        let mailKey = ReadingPositionKey.mail(messageID: "<m@x>", folder: "INBOX", uid: 7)
        cache.set(ReadingPosition(offset: 640), for: mailKey)
        store.savePositions(cache)
        let loaded = store.loadPositions()
        XCTAssertEqual(loaded.position(for: "feed:feed#key")?.anchor, "i2.0.5|-12")
        XCTAssertEqual(loaded.position(for: "mail:<m@x>")?.offset, 640)
        XCTAssertEqual(loaded.capacity, 10)
        XCTAssertEqual(loaded.order, cache.order)
    }

    func testPositionCacheDecodeRebuildsOrderFromEntries() throws {
        // `order` names a key with no entry and omits one that exists.
        let json = """
        {"capacity":4,"order":["ghost","a"],"entries":{"a":{"anchor":"i1|0","savedAt":0},"b":{"offset":3,"savedAt":0}}}
        """
        let cache = try JSONDecoder().decode(ReadingPositionCache.self, from: Data(json.utf8))
        XCTAssertEqual(cache.order, ["a", "b"])
        XCTAssertEqual(cache.count, 2)
    }

    func testMailKeyPrefersMessageID() {
        XCTAssertEqual(ReadingPositionKey.mail(messageID: "<id>", folder: "F", uid: 1), "mail:<id>")
        XCTAssertEqual(ReadingPositionKey.mail(messageID: "", folder: "F", uid: 1), "mail:F#1")
        XCTAssertEqual(ReadingPositionKey.mail(messageID: nil, folder: "F", uid: 1), "mail:F#1")
    }

    // MARK: Store

    func testOfferedForeignUpdatedAtAndClear() {
        let store = ResumeSessionStore(defaults: defaults)
        XCTAssertEqual(store.offeredForeignUpdatedAt, 0)
        store.offeredForeignUpdatedAt = 1_719_600_000_000
        XCTAssertEqual(store.offeredForeignUpdatedAt, 1_719_600_000_000)
        store.saveSession(ResumeSession(section: .mail, folder: "INBOX"))
        var cache = ReadingPositionCache()
        cache.set(ReadingPosition(offset: 1), for: "k")
        store.savePositions(cache)
        store.clear()
        XCTAssertNil(store.loadSession())
        XCTAssertEqual(store.loadPositions().count, 0)
        XCTAssertEqual(store.offeredForeignUpdatedAt, 0)
        XCTAssertNil(ResumeSessionStore.storedSection(defaults: defaults))
    }
}
