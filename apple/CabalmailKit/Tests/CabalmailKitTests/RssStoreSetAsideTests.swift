import XCTest
@testable import CabalmailKit

/// A temporary feed store directory, and the stores and set-aside files the
/// set-aside tests plant in it.
class RssSetAsideTestCase: XCTestCase {
    typealias Queued = RssStore.QueuedChange

    var directory: URL!
    var live: URL { directory.appendingPathComponent("rss.sqlite") }
    var aside: SQLiteSetAside { RssStore.setAside(in: directory) }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-set-aside-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    let published = "2026-01-02T00:00:00Z"

    /// A store with one subscription and items a, b and c, handed to `body`
    /// and released when it returns, which closes its file.
    func withSeededStore(_ body: (RssStore) async throws -> Void) async throws {
        let store = try RssStore(directory: directory)
        try await seed(store)
        try await body(store)
    }

    func seed(_ store: RssStore) async throws {
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        try await store.upsertItems(["a", "b", "c"].map {
            RssItem(feedId: "f1", itemId: $0, sortKey: $0, publishedAt: published)
        })
    }

    func raw<Output>(_ file: URL, _ body: (SQLiteDatabase) throws -> Output) throws -> Output {
        let database = try SQLiteDatabase(path: file.path, existing: true)
        defer { database.close() }
        return try body(database)
    }

    func queue(in file: URL) throws -> [Queued] {
        try raw(file) { database in
            try database.rows("SELECT \(Queued.columns) FROM pending ORDER BY id").map(Queued.init(row:))
        }
    }

    /// A set-aside file holding `changes`, named for `stamp` so files sort
    /// in the order the stamps give. It is at the feed schema unless
    /// `schema` names an older one: a file from before version 7 has no
    /// `slot` column, so its changes are written without one.
    @discardableResult
    func makeSetAsideFile(stamp: Int, schema: Int = RssStore.schemaVersion, _ changes: [Queued]) throws -> URL {
        try FileManager.default.createDirectory(at: aside.directory, withIntermediateDirectories: true)
        let file = aside.directory.appendingPathComponent(String(format: "rss-%013ld-test0000.sqlite", stamp))
        let database = try SQLiteDatabase(path: file.path)
        defer { database.close() }
        try SchemaMigrator(name: "rss.sqlite", steps: Array(RssStore.migrator.steps.prefix(schema)))
            .migrate(database, newerSchema: .refuse)
        for change in changes {
            try insert(change, into: database, withSlot: schema >= 7)
        }
        return file
    }

    /// One queue row, written as a file of that schema holds it.
    func insert(_ change: Queued, into database: SQLiteDatabase, withSlot: Bool = true) throws {
        let binds: [SQLiteDatabase.Value] = [
            .init(change.kind), .init(change.feedId), .init(change.sortKey), .init(change.subscriptionId),
            .init(change.value), .init(change.createdAt),
        ]
        if withSlot {
            try database.run("INSERT INTO pending (\(Queued.columns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
                             binds + [.init(change.slot)])
        } else {
            try database.run("""
                INSERT INTO pending (kind, feed_id, sort_key, subscription_id, value, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, binds)
        }
    }

    func read(_ item: String, _ value: Bool, at time: String) -> Queued {
        Queued(kind: "read", feedId: "f1", sortKey: item, value: value ? 1 : 0, createdAt: time)
    }

    func favorite(_ item: String, at time: String) -> Queued {
        Queued(kind: "favorite", feedId: "f1", sortKey: item, value: 1, createdAt: time)
    }

    func markAllRead(at watermark: String) -> Queued {
        Queued(kind: "mark_all_read", feedId: "f1", subscriptionId: "s1", createdAt: watermark)
    }

    /// A change to one custom flag of an item: an add, or a remove.
    func flag(_ item: String, _ slot: String, _ isSet: Bool, at time: String) -> Queued {
        Queued(kind: "flag", feedId: "f1", sortKey: item, value: isSet ? 1 : 0, createdAt: time, slot: slot)
    }
}

/// A feed store that cannot be opened is set aside, not deleted, because the
/// file also holds the queue of changes not yet sent; and every open brings
/// back the queue of each set-aside file the build can read. Together they
/// are what lets a tester install an older build and come back without
/// losing unsent feed marks.
final class RssStoreSetAsideTests: RssSetAsideTestCase {
    // MARK: - Set aside, not deleted

    func testAFileFromANewerBuildIsSetAsideWithItsQueueIntact() async throws {
        try await withSeededStore { try await $0.setRead(feedId: "f1", sortKey: "a", true) }
        try raw(live) { try $0.setUserVersion(RssStore.schemaVersion + 1) }

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let subscriptions = try await opened.subscriptions()
        XCTAssertEqual(subscriptions, [], "the new store starts empty; the next sync repopulates it")
        let queued = try await opened.pendingCount()
        XCTAssertEqual(queued, 0, "a queue this build cannot read is not brought back")
        XCTAssertEqual(try raw(live) { try $0.userVersion() }, RssStore.schemaVersion)
        let files = aside.files()
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try raw(file) { try $0.userVersion() }, RssStore.schemaVersion + 1)
        XCTAssertEqual(try queue(in: file).map(\.kind), ["read"], "the unsent mark is still in the file")
        XCTAssertEqual(try raw(file) { try $0.rows("SELECT COUNT(*) FROM items").first?.int(0) }, 3)
    }

    func testADamagedFileIsSetAsideByteForByte() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damage = Data(repeating: 0xA5, count: 8192)
        try damage.write(to: live)

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        try await opened.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        let file = try XCTUnwrap(aside.files().first)
        XCTAssertEqual(aside.files().count, 1)
        XCTAssertEqual(try Data(contentsOf: file), damage)
    }

    // MARK: - The queue comes back

    /// The downgrade and the return. This build stands in for both: as the
    /// older one, it meets a file whose version is past its own; as the
    /// newer one returning, it meets that file set aside at a version it
    /// reads.
    func testUnsentMarksSurviveADowngradeAndTheReturn() async throws {
        try await withSeededStore { store in
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            try await store.setFavorite(feedId: "f1", sortKey: "b", true)
            try await store.markAllRead(subscriptionId: "s1", watermark: "2026-03-01T00:00:00Z")
        }
        try raw(live) { try $0.setUserVersion(RssStore.schemaVersion + 1) }

        // The older build opens it, sets it aside, and is used for a while.
        do {
            let older = try XCTUnwrap(RssStore.openRecovering(directory: directory))
            let queued = try await older.pendingCount()
            XCTAssertEqual(queued, 0)
        }
        let file = try XCTUnwrap(aside.files().first)
        try raw(file) { try $0.setUserVersion(RssStore.schemaVersion) }

        // The newer build returns.
        let newer = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await newer.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.read, .favorite, .markAllRead])
        XCTAssertEqual(queued.map(\.sortKey), ["a", "b", ""])
        XCTAssertEqual(queued.map(\.value), [true, true, false])
        XCTAssertEqual(queued.last?.subscriptionId, "s1")
        XCTAssertEqual(queued.last?.watermark, "2026-03-01T00:00:00Z", "the tap-time watermark, not the return's")
        XCTAssertEqual(aside.files(), [], "a file whose queue is back is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.directory.path),
                       "and the directory with the last one")
    }

    /// A file this build can read but could not migrate used to be deleted
    /// with its queue. It is set aside and read back in the same open.
    func testAFileThatFailsToMigrateKeepsItsQueue() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: live.path)
            defer { database.close() }
            try database.exec(Schema.version1)
            try database.exec(Schema.version2)
            try database.exec(Schema.version3)
            // Half of version 4, so its rerun fails on a duplicate column.
            try database.exec("ALTER TABLE subscriptions ADD COLUMN default_filter TEXT NOT NULL DEFAULT 'unread'")
            try database.run("""
                INSERT INTO pending (kind, feed_id, sort_key, value, created_at)
                VALUES ('read', 'f1', 'a', 1, '2026-01-03T00:00:00Z')
                """)
            try database.setUserVersion(3)
        }
        XCTAssertThrowsError(try RssStore(directory: directory))

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.read])
        XCTAssertEqual(queued.map(\.sortKey), ["a"])
        XCTAssertEqual(aside.files(), [])
    }

    func testAnItemShowsTheChangeThatCameBack() async throws {
        try await withSeededStore { _ in }
        try makeSetAsideFile(stamp: 1, [read("a", true, at: "2026-02-01T00:00:00Z"),
                                        favorite("b", at: "2026-02-01T00:00:01Z")])

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let marked = try await opened.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(marked?.isRead, true, "the list shows what the queue will send")
        let starred = try await opened.item(feedId: "f1", sortKey: "b")
        XCTAssertEqual(starred?.isFavorite, true)
        let untouched = try await opened.item(feedId: "f1", sortKey: "c")
        XCTAssertEqual(untouched?.isRead, false)
        let showsQueued = try await opened.hasPending(feedId: "f1", sortKey: "a")
        XCTAssertTrue(showsQueued)
    }

    /// An older mark-all-read that comes back must not undo a newer mark
    /// made since: the queue's changes are shown again in order, so the
    /// item ends as the last change to it says.
    func testAnOlderMarkAllReadDoesNotUndoANewerMarkMadeSince() async throws {
        try await withSeededStore { try await $0.setRead(feedId: "f1", sortKey: "a", false) }
        try makeSetAsideFile(stamp: 1, [markAllRead(at: "2026-06-01T00:00:00Z")])

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.markAllRead, .read], "the older change replays first")
        let item = try await opened.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(item?.isRead, false, "the newer explicit unread stands")
        let other = try await opened.item(feedId: "f1", sortKey: "b")
        XCTAssertEqual(other?.isRead, true, "the mark-all-read that came back reads the rest")
    }

    // MARK: - Order and precedence

    func testChangesThatComeBackGoInFrontOfTheLiveQueueOldestFileFirst() async throws {
        try await withSeededStore { try await $0.setRead(feedId: "f1", sortKey: "c", true) }
        try makeSetAsideFile(stamp: 2, [favorite("b", at: "2026-02-02T00:00:00Z")])
        try makeSetAsideFile(stamp: 1, [markAllRead(at: "2026-02-01T00:00:00Z"),
                                        read("a", false, at: "2026-02-01T00:00:05Z")])

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map { "\($0.kind.rawValue) \($0.sortKey)" },
                       ["mark_all_read ", "read a", "favorite b", "read c"])
        XCTAssertEqual(queued.map(\.id), queued.map(\.id).sorted(), "the drain replays in this order")
    }

    func testOfTwoChangesToOneItemAndKindTheLaterStays() {
        let earlier = read("a", true, at: "2026-02-01T00:00:00Z")
        let later = read("a", false, at: "2026-02-02T00:00:00Z")
        let otherKind = favorite("a", at: "2026-02-01T00:00:00Z")

        XCTAssertEqual(RssStore.merged(restored: [earlier], live: [later]), [later])
        XCTAssertEqual(RssStore.merged(restored: [later], live: [earlier]), [later],
                       "by created_at, whichever file it was in")
        XCTAssertEqual(RssStore.merged(restored: [earlier, otherKind], live: [later]), [otherKind, later],
                       "a different kind for the same item is its own change")
        let sameSecond = read("a", false, at: earlier.createdAt)
        XCTAssertEqual(RssStore.merged(restored: [earlier], live: [sameSecond]), [sameSecond],
                       "on a tie the live one, which was made after the file was set aside")
    }

    func testBringingTheSameChangesBackTwiceAddsNothing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: live.path)
        defer { database.close() }
        try RssStore.migrator.migrate(database, newerSchema: .refuse)
        let changes = [markAllRead(at: "2026-02-01T00:00:00Z"), read("a", true, at: "2026-02-01T00:00:05Z")]

        try RssStore.restore(changes, into: database)
        try RssStore.restore(changes, into: database)

        XCTAssertEqual(try queue(in: live), changes)
    }

}

/// What becomes of set-aside files afterwards: the ones no build here can
/// read are bounded, sign-out deletes them all, and a restore that fails
/// leaves its file for the next open.
final class RssStoreSetAsideUpkeepTests: RssSetAsideTestCase {
    // MARK: - Files this build cannot read

    func testOnlyTheNewestThreeFilesThisBuildCannotReadAreKept() async throws {
        try FileManager.default.createDirectory(at: aside.directory, withIntermediateDirectories: true)
        let names = (1...5).map { String(format: "rss-%013ld-test0000.sqlite", $0) }
        for name in names {
            try Data(repeating: 0xA5, count: 4096).write(to: aside.directory.appendingPathComponent(name))
        }
        let oldestSideFile = aside.directory.appendingPathComponent(names[0] + "-wal")
        try Data([0x00]).write(to: oldestSideFile)

        _ = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        XCTAssertEqual(aside.files().map(\.lastPathComponent), Array(names.suffix(3)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestSideFile.path),
                       "a deleted file's side files go with it")
    }

    /// The limit is on unread files only: one this build reads is brought
    /// back and deleted however many others wait.
    func testAReadableFileAmongUnreadableOnesStillComesBack() async throws {
        try FileManager.default.createDirectory(at: aside.directory, withIntermediateDirectories: true)
        for stamp in [1, 2, 4, 5] {
            let name = String(format: "rss-%013ld-test0000.sqlite", stamp)
            try Data(repeating: 0xA5, count: 4096).write(to: aside.directory.appendingPathComponent(name))
        }
        try makeSetAsideFile(stamp: 3, [read("a", true, at: "2026-02-01T00:00:00Z")])

        let opened = try XCTUnwrap(RssStore.openRecovering(directory: directory))

        let queued = try await opened.pendingMutations()
        XCTAssertEqual(queued.map(\.sortKey), ["a"])
        XCTAssertEqual(aside.files().map(\.lastPathComponent),
                       [2, 4, 5].map { String(format: "rss-%013ld-test0000.sqlite", $0) })
    }

    // MARK: - Sign-out

    /// A set-aside file holds the last account's unsent marks, which the
    /// next account's store would bring back and send as its own.
    func testClearingTheStoreDeletesTheSetAsideFiles() async throws {
        let store = try RssStore(directory: directory)
        try makeSetAsideFile(stamp: 1, [read("a", true, at: "2026-02-01T00:00:00Z")])
        try Data(repeating: 0xA5, count: 4096)
            .write(to: aside.directory.appendingPathComponent("rss-0000000000002-test0000.sqlite"))

        try await store.clear()

        XCTAssertEqual(aside.files(), [])
        let next = try XCTUnwrap(RssStore.openRecovering(directory: directory))
        let queued = try await next.pendingCount()
        XCTAssertEqual(queued, 0, "the next store on the directory finds nothing to bring back")
    }

    func testRetiringTheStoreDeletesTheSetAsideFiles() async throws {
        let store = try RssStore(directory: directory)
        try makeSetAsideFile(stamp: 1, [read("a", true, at: "2026-02-01T00:00:00Z")])

        try await store.retire()

        XCTAssertEqual(aside.files(), [])
    }

    // MARK: - With the write-failure switch

    #if DEBUG
    /// A failure while the queue is being put back changes nothing and
    /// leaves the file for the next open.
    func testAFailedRestoreLeavesTheFileForTheNextOpen() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: live.path)
        defer { database.close() }
        try RssStore.migrator.migrate(database, newerSchema: .refuse)
        let kept = read("c", true, at: "2026-02-03T00:00:00Z")
        try insert(kept, into: database)
        let comingBack = [read("a", true, at: "2026-02-01T00:00:00Z")]
        try makeSetAsideFile(stamp: 1, comingBack)
        database.faults.arm(table: "pending")

        RssStore.recoverSetAside(into: database, directory: directory)

        XCTAssertEqual(try queue(in: live), [kept], "the live queue is as it was")
        XCTAssertEqual(aside.files().count, 1, "the file waits for the next open")

        RssStore.recoverSetAside(into: database, directory: directory)

        XCTAssertEqual(try queue(in: live), comingBack + [kept])
        XCTAssertEqual(aside.files(), [])
    }
    #endif
}
