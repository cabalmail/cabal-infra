import XCTest
@testable import CabalmailKit

/// Feed schema 7 (custom flags on items, and the slot a queued flag change
/// is about) against the files that came before it and the builds that
/// cannot read it: a schema 6 store migrates with its rows and queue, an
/// older build's set-aside of a schema 7 file gives its flag changes back,
/// and a set-aside file from schema 6, which has no `slot` column, still
/// comes back.
final class RssStoreFlagSetAsideTests: RssSetAsideTestCase {
    private let slot3 = "cabal-flag-03"
    private let slot5 = "cabal-flag-05"

    /// The steps up to `schema`, as the build that shipped it ran them.
    private func migrator(through schema: Int) -> SchemaMigrator {
        SchemaMigrator(name: "rss.sqlite", steps: Array(RssStore.migrator.steps.prefix(schema)))
    }

    private func columns(of table: String, in file: URL) throws -> [String] {
        try raw(file) { database in
            try database.rows("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.init(table)])
                .map { $0.string(0) }
        }
    }

    // MARK: - 6 to 7

    func testASchemaSixStoreMigratesWithItsItemsAndItsQueue() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: live.path)
            defer { database.close() }
            try migrator(through: 6).migrate(database, newerSchema: .refuse)
            try database.run("INSERT INTO subscriptions (subscription_id, feed_id) VALUES ('s1', 'f1')")
            try database.run("""
                INSERT INTO items (feed_id, sort_key, item_id, title, published_at, is_favorite)
                VALUES ('f1', 'a', 'a', 'Kept', '2026-01-02T00:00:00Z', 1)
                """)
            try insert(read("a", true, at: "2026-02-01T00:00:00Z"), into: database, withSlot: false)
            try insert(favorite("a", at: "2026-02-01T00:00:01Z"), into: database, withSlot: false)
            try insert(markAllRead(at: "2026-02-01T00:00:02Z"), into: database, withSlot: false)
        }
        XCTAssertEqual(try raw(live) { try $0.userVersion() }, 6)
        XCTAssertFalse(try columns(of: "pending", in: live).contains("slot"), "the file is as schema 6 left it")

        let store = try RssStore(directory: directory)

        XCTAssertEqual(try raw(live) { try $0.userVersion() }, 7)
        XCTAssertTrue(try columns(of: "items", in: live).contains("flags"))
        XCTAssertTrue(try columns(of: "pending", in: live).contains("slot"))
        let item = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.title, "Kept")
        XCTAssertEqual(item?.isFavorite, true)
        XCTAssertEqual(item?.flags, [], "an item from before flags has none")
        let queued = try await store.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.read, .favorite, .markAllRead], "the queue is intact, in order")
        XCTAssertEqual(queued.map(\.slot), ["", "", ""])
        XCTAssertEqual(queued.last?.watermark, "2026-02-01T00:00:02Z")

        // And the migrated file takes a flag change like any other.
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        let flagged = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(flagged?.flags, [slot3])
        // A later read mark still replaces the migrated one: its empty slot
        // is the same key a new row has.
        try await store.setRead(feedId: "f1", sortKey: "a", false)
        let reads = try await store.pendingMutations().filter { $0.kind == .read }
        XCTAssertEqual(reads.map(\.value), [false])
    }

    // MARK: - A schema 7 file set aside by an older build

    /// The downgrade and the return, with flag changes in the queue. This
    /// build stands in for both, as in `RssStoreSetAsideTests`: as the
    /// older one it meets a file whose version is past its own, and as the
    /// newer one returning it meets that file set aside at a version it
    /// reads. Two changes to one item's flags are two rows, and both must
    /// come back.
    func testFlagChangesSurviveADowngradeAndTheReturn() async throws {
        try await withSeededStore { store in
            try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
            try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot5, true)
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            try await store.upsertItems([
                RssItem(feedId: "f1", itemId: "b", sortKey: "b", publishedAt: published, flags: [slot3]),
            ])
            try await store.setFlag(feedId: "f1", sortKey: "b", slot: slot3, false)
        }
        try raw(live) { try $0.setUserVersion(RssStore.schemaVersion + 1) }

        // The older build opens it, sets it aside, and refetches its items.
        do {
            let older = try XCTUnwrap(RssStore.openRecovering(directory: directory))
            let queued = try await older.pendingCount()
            XCTAssertEqual(queued, 0)
            try await seed(older)
            try await older.upsertItems([
                RssItem(feedId: "f1", itemId: "b", sortKey: "b", publishedAt: published, flags: [slot3]),
            ])
        }
        let file = try XCTUnwrap(aside.files().first)
        try raw(file) { try $0.setUserVersion(RssStore.schemaVersion) }

        // The newer build returns.
        let newer = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await newer.pendingMutations()
        XCTAssertEqual(queued.map { "\($0.kind.rawValue) \($0.sortKey) \($0.slot) \($0.value)" }, [
            "flag a \(slot3) true", "flag a \(slot5) true", "read a  true", "flag b \(slot3) false",
        ])
        let both = try await newer.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(both?.flags, [slot3, slot5], "the list shows what the queue will send")
        let cleared = try await newer.item(feedId: "f1", sortKey: "b")
        XCTAssertEqual(cleared?.flags, [], "and a queued remove shows as removed")
        XCTAssertEqual(aside.files(), [])
    }

    // MARK: - A schema 6 file set aside

    /// A file a schema 6 build left (set aside because it could not be
    /// opened then, say) has no `slot` column. Its queue is read without it.
    func testASetAsideFileFromSchemaSixStillComesBack() async throws {
        try await withSeededStore { _ in }
        let file = try makeSetAsideFile(stamp: 1, schema: 6, [
            read("a", true, at: "2026-02-01T00:00:00Z"),
            favorite("b", at: "2026-02-01T00:00:01Z"),
            markAllRead(at: "2026-02-01T00:00:02Z"),
        ])
        XCTAssertFalse(try columns(of: "pending", in: file).contains("slot"))

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.read, .favorite, .markAllRead])
        XCTAssertEqual(queued.map(\.slot), ["", "", ""])
        let marked = try await opened.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(marked?.isRead, true)
        XCTAssertEqual(aside.files(), [], "a file whose queue is back is deleted")
    }

    // MARK: - Precedence, by item, kind and slot

    func testChangesToTwoFlagsOfOneItemAreTwoChanges() {
        let three = flag("a", slot3, true, at: "2026-02-01T00:00:00Z")
        let five = flag("a", slot5, true, at: "2026-02-01T00:00:00Z")
        let threeOff = flag("a", slot3, false, at: "2026-02-02T00:00:00Z")

        XCTAssertEqual(RssStore.merged(restored: [three], live: [five]), [three, five],
                       "a change to another slot of the item does not replace this one")
        XCTAssertEqual(RssStore.merged(restored: [three, five], live: [threeOff]), [five, threeOff],
                       "of two changes to one slot the later stays")
        XCTAssertEqual(RssStore.merged(restored: [threeOff], live: [three]), [threeOff],
                       "by created_at, whichever file it was in")
    }

    /// A flag change that comes back meets the live queue slot by slot, and
    /// the item ends as the queue will leave it.
    func testAFlagChangeThatComesBackMeetsTheLiveQueueBySlot() async throws {
        try await withSeededStore { store in
            try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        }
        try makeSetAsideFile(stamp: 1, [
            flag("a", slot3, false, at: "2026-02-01T00:00:00Z"),
            flag("a", slot5, true, at: "2026-02-01T00:00:01Z"),
        ])

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map { "\($0.slot) \($0.value)" }, ["\(slot5) true", "\(slot3) true"],
                       "the live add of slot 3 is later than the remove that came back")
        let item = try await opened.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.flags, [slot3, slot5])
    }
}
