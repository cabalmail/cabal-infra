import XCTest
@testable import CabalmailKit

/// `RssStore`'s per-flag listing and count (`ItemQuery.flag`, `flagCount`):
/// what a feed list shows, and the number on its pill, while it is narrowed
/// to one flag or to any flag.
///
/// The oracle is `FlagCriterion.matches`, the rule a mail list applies to
/// the rows it holds, so the two media cannot come to mean different things
/// by one filter.
final class RssStoreFlagFilterTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    private let slot1 = "cabal-flag-01"
    private let slot3 = "cabal-flag-03"
    private let slot10 = "cabal-flag-10"
    private let slot11 = "cabal-flag-11"

    /// Every criterion the tests ask for: the built-in flag, three slots
    /// that share digits, a slot nothing carries, and any flag.
    private var criteria: [FlagCriterion] {
        [.slot(FlagPalette.systemSlot), .slot(slot1), .slot(slot3), .slot(slot10), .slot(slot11),
         .slot("cabal-flag-20"), .any]
    }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-flag-filter-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        _ = try await store.replaceCatalog(RssCatalog(
            folders: [RssFolder(folderId: "d", name: "Tech")],
            subscriptions: [
                RssSubscription(subscriptionId: "s1", feedId: "f1", folderId: "d",
                                readWatermark: "2026-01-04T12:00:00Z"),
                RssSubscription(subscriptionId: "s2", feedId: "f2"),
            ]
        ))
        // One item for each way the marks can fall, across two feeds, so no
        // two criteria list the same rows.
        try await store.upsertItems([
            item("plain", feed: "f1", day: 1),
            item("favorite", feed: "f1", day: 2, favorite: true),
            item("one", feed: "f1", day: 3, flags: [slot1]),
            item("three", feed: "f1", day: 4, flags: [slot3]),
            item("both", feed: "f2", day: 5, flags: [slot1, slot3]),
            item("favorite-three", feed: "f2", day: 6, favorite: true, flags: [slot3]),
            item("ten-eleven", feed: "f2", day: 7, flags: [slot10, slot11]),
            item("cleared", feed: "f2", day: 8),
            item("unset-by-server", feed: "f2", day: 9, flags: [slot1]),
        ])
        // A flag set and taken off again here, and one the server takes off:
        // both leave the column as an item that never had one.
        try await store.setFlag(feedId: "f2", sortKey: "cleared", slot: slot3, true)
        try await store.setFlag(feedId: "f2", sortKey: "cleared", slot: slot3, false)
        try await store.applyServerStates([RssItemState(feedId: "f2", sortKey: "unset-by-server")])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(
        _ key: String, feed: String, day: Int, favorite: Bool = false, flags: Set<String> = []
    ) -> RssItem {
        RssItem(feedId: feed, itemId: key, sortKey: key, publishedAt: "2026-01-0\(day)T00:00:00Z",
                isFavorite: favorite, flags: flags)
    }

    /// What an item carries as the flag set a criterion reads: its custom
    /// slots, and the built-in flag for the favorite bit.
    private func carried(_ item: RssItem) -> Set<Flag> {
        var flags = Set(item.flags.map(Flag.keyword))
        if item.isFavorite { flags.insert(.flagged) }
        return flags
    }

    private func listed(_ criterion: FlagCriterion, in scope: RssItemScope = .all,
                        filter: RssItemFilter = .all) async throws -> Set<String> {
        Set(try await store.items(.init(scope: scope, filter: filter, flag: criterion, limit: 1000))
            .map(\.sortKey))
    }

    func testEachCriterionListsExactlyTheItemsItMatches() async throws {
        let everything = try await store.items(.init(scope: .all, limit: 1000))
        XCTAssertEqual(everything.count, 9)

        for criterion in criteria {
            let rows = try await listed(criterion)
            let expected = Set(everything.filter { criterion.matches(carried($0)) }.map(\.sortKey))
            XCTAssertEqual(rows, expected, "\(criterion)")
        }
        // Spelled out, so a rule that is wrong in the store and in `matches`
        // alike still fails here.
        let system = try await listed(.slot(FlagPalette.systemSlot))
        XCTAssertEqual(system, ["favorite", "favorite-three"])
        let one = try await listed(.slot(slot1))
        XCTAssertEqual(one, ["one", "both"], "not the slot-10 and slot-11 item, whose digits it shares")
        let three = try await listed(.slot(slot3))
        XCTAssertEqual(three, ["three", "both", "favorite-three"])
        let ten = try await listed(.slot(slot10))
        XCTAssertEqual(ten, ["ten-eleven"])
        let unused = try await listed(.slot("cabal-flag-20"))
        XCTAssertEqual(unused, [])
        let any = try await listed(.any)
        XCTAssertEqual(any, ["favorite", "one", "three", "both", "favorite-three", "ten-eleven"],
                       "not the item whose flag was cleared, nor the one the server cleared")
    }

    func testTheCountIsTheNumberOfRowsListedInEveryScope() async throws {
        for scope in [RssItemScope.subscription("s1"), .subscription("s2"), .folder("d"), .all] {
            for criterion in criteria {
                let rows = try await listed(criterion, in: scope)
                let count = try await store.flagCount(in: scope, matching: criterion)
                XCTAssertEqual(count, rows.count, "\(scope) \(criterion)")
            }
        }
        let slotThreeEverywhere = try await store.flagCount(in: .all, matching: .slot(slot3))
        let slotThreeInOneFeed = try await store.flagCount(in: .subscription("s1"), matching: .slot(slot3))
        let anyEverywhere = try await store.flagCount(in: .all, matching: .any)
        XCTAssertEqual([slotThreeEverywhere, slotThreeInOneFeed, anyEverywhere], [3, 1, 6])
    }

    func testAnEmptyScopeListsAndCountsNothing() async throws {
        let rows = try await listed(.any, in: .folder("missing"))
        let count = try await store.flagCount(in: .folder("missing"), matching: .any)

        XCTAssertEqual(rows, [])
        XCTAssertEqual(count, 0)
    }

    /// The flag narrows what the pill's own filter leaves: an item must pass
    /// both.
    func testAFlagAndAFilterMustBothHold() async throws {
        // Everything in f1 is older than its read watermark, `three` too, so
        // only the f2 items carrying slot 3 are unread.
        let unread = try await listed(.slot(slot3), filter: .unread)
        XCTAssertEqual(unread, ["both", "favorite-three"])
        let favorite = try await listed(.slot(slot3), filter: .favorite)
        XCTAssertEqual(favorite, ["favorite-three"])
    }

    /// A flag's rows, paged one at a time in every ordering, are the rows of
    /// one unpaged read: the flag still narrows page two, and what the
    /// clause binds sits between the feeds and the page boundary.
    func testEveryPageKeepsTheFlagInEveryOrdering() async throws {
        let orderings: [RssOrderingMode] = [.newestFirst, .oldestFirst, .newestDayOldestWithin, .oldestDayNewestWithin]
        for criterion in [FlagCriterion.slot(slot3), .slot(FlagPalette.systemSlot), .any] {
            for ordering in orderings {
                let full = try await store.items(.init(scope: .all, flag: criterion, ordering: ordering, limit: 100))
                XCTAssertGreaterThan(full.count, 1, "\(criterion)")
                var walked: [RssItem] = []
                while walked.count <= full.count {
                    let next = try await store.items(.init(
                        scope: .all, flag: criterion, ordering: ordering, limit: 1,
                        after: walked.last.map(RssStore.ItemCursor.init(after:))
                    ))
                    guard let row = next.first else { break }
                    walked.append(row)
                }
                XCTAssertEqual(walked.map(\.sortKey), full.map(\.sortKey), "\(criterion) \(ordering)")
            }
        }
    }

    func testAnItemWhoseLastFlagIsTakenOffLeavesAnyFlag() async throws {
        try await store.setFlag(feedId: "f1", sortKey: "one", slot: slot1, false)

        let any = try await listed(.any)
        let count = try await store.flagCount(in: .all, matching: .any)
        XCTAssertFalse(any.contains("one"))
        XCTAssertEqual(count, 5)
    }

    func testAnItemWithoutFlagsIsListedAsBefore() async throws {
        let unfiltered = try await store.items(.init(scope: .all, limit: 1000))
        let favorites = try await store.items(.init(scope: .all, filter: .favorite, limit: 1000))

        XCTAssertEqual(unfiltered.count, 9, "a query that names no flag is not narrowed")
        XCTAssertEqual(Set(favorites.map(\.sortKey)), ["favorite", "favorite-three"])
    }

    // MARK: - What the clause relies on

    /// The clause finds a slot between its quotes in the column's text and
    /// takes two bytes for an empty list, so the text's shape is part of the
    /// query: compact, sorted, `[]` when empty.
    func testTheStoredTextIsACompactSortedList() {
        XCTAssertEqual(RssStoredFlags.encode([]), "[]")
        XCTAssertEqual(RssStoredFlags.encode([slot3]), "[\"cabal-flag-03\"]")
        XCTAssertEqual(RssStoredFlags.encode([slot10, slot1, slot3]),
                       "[\"cabal-flag-01\",\"cabal-flag-03\",\"cabal-flag-10\"]")
    }

    /// The clause has two spellings, one for a SQLite that can tell a
    /// non-empty list from the row's header. They must agree with each other
    /// and with `FlagCriterion.matches` on every row.
    func testBothSpellingsOfTheClauseAgreeWithTheRule() throws {
        let database = try SQLiteDatabase(path: tempDir.appendingPathComponent("clause.sqlite").path)
        defer { database.close() }
        try database.exec("CREATE TABLE items (name TEXT, is_favorite INTEGER, flags TEXT NOT NULL DEFAULT '[]')")
        let rows = [
            item("plain", feed: "f", day: 1), item("favorite", feed: "f", day: 1, favorite: true),
            item("one", feed: "f", day: 1, flags: [slot1]), item("both", feed: "f", day: 1, flags: [slot1, slot3]),
            item("favorite-three", feed: "f", day: 1, favorite: true, flags: [slot3]),
            item("ten-eleven", feed: "f", day: 1, flags: [slot10, slot11]),
        ]
        for row in rows {
            try database.run("INSERT INTO items (name, is_favorite, flags) VALUES (?, ?, ?)",
                             [.init(row.sortKey), .init(row.isFavorite), .init(RssStoredFlags.encode(row.flags))])
        }
        try database.run("INSERT INTO items (name, is_favorite) VALUES ('defaulted', 0)")

        var spellings = [false]
        if SQLiteDatabase.hasOctetLength { spellings.append(true) }
        for byteLength in spellings {
            for criterion in criteria + [.slot("$Forwarded")] {
                let clause = RssStore.flagClause(criterion, byteLength: byteLength)
                let found = Set(try database.rows("SELECT i.name FROM items i WHERE \(clause.sql)", clause.binds)
                    .map { $0.string(0) })
                let expected = Set(rows.filter { criterion.matches(carried($0)) }.map(\.sortKey))
                XCTAssertEqual(found, expected, "\(criterion), byteLength \(byteLength)")
            }
        }
    }

    func testThisSQLiteCanReadALengthFromTheRowHeader() {
        // Every OS the Kit builds for ships SQLite 3.43 or later; were one
        // not to, the plain spelling above is what its queries would use.
        XCTAssertTrue(SQLiteDatabase.hasOctetLength)
    }
}
