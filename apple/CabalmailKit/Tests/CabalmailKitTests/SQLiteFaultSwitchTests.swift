#if DEBUG
import XCTest
@testable import CabalmailKit

/// The debug-only write-failure switch: `-CabalmailFailNextWrite <table>`
/// fails the next write to that table once, so a soak can show live what a
/// store does when SQLite refuses a write.
final class SQLiteFaultSwitchTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("test.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-sqlite-fault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: path)
        try database.exec("""
            CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT);
            CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY, name TEXT);
            """)
        return database
    }

    private func count(_ table: String, in database: SQLiteDatabase) throws -> Int {
        try database.rows("SELECT COUNT(*) FROM \(table)").first?.int(0) ?? 0
    }

    private func assertInjected(_ expression: @autoclosure () throws -> Void, table: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case CabalmailError.storage(let detail) = error else {
                return XCTFail("an injected fault is a storage error, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(detail, "injected fault: a write to \(table) was failed (-CabalmailFailNextWrite)",
                           file: file, line: line)
        }
    }

    // MARK: - One connection

    func testTheNextWriteToTheNamedTableFailsOnceAndOnlyThere() throws {
        let database = try makeDatabase()
        database.faults.arm(table: "notes")

        // Another table's write and a read of the named one do not trip it.
        try database.run("INSERT INTO tags (name) VALUES ('a')")
        XCTAssertEqual(try count("notes", in: database), 0)

        assertInjected(try database.run("INSERT INTO notes (body) VALUES ('first')"), table: "notes")
        XCTAssertEqual(try count("notes", in: database), 0, "the failed write wrote nothing")

        try database.run("INSERT INTO notes (body) VALUES ('second')")
        XCTAssertEqual(try database.rows("SELECT body FROM notes").map { $0.string(0) }, ["second"],
                       "the switch is spent: the write after the failed one runs")
    }

    func testAnUpdateADeleteAndAnExecEachCountAsAWrite() throws {
        let database = try makeDatabase()
        try database.run("INSERT INTO notes (body) VALUES ('x')")

        database.faults.arm(table: "notes")
        assertInjected(try database.run("UPDATE notes SET body = 'y'"), table: "notes")
        database.faults.arm(table: "notes")
        assertInjected(try database.run("DELETE FROM notes WHERE id = 1"), table: "notes")
        database.faults.arm(table: "notes")
        assertInjected(try database.exec("DELETE FROM tags; DELETE FROM notes;"), table: "notes")

        XCTAssertEqual(try database.rows("SELECT body FROM notes").map { $0.string(0) }, ["x"])
    }

    func testAWriteMadeByATriggerCounts() throws {
        let database = try makeDatabase()
        try database.exec("""
            CREATE TRIGGER tag_each_note AFTER INSERT ON notes
            BEGIN INSERT INTO tags (name) VALUES (new.body); END
            """)
        database.faults.arm(table: "tags")

        assertInjected(try database.run("INSERT INTO notes (body) VALUES ('x')"), table: "tags")

        XCTAssertEqual(try count("notes", in: database), 0, "the statement whose trigger was refused did not run")
    }

    /// What the switch is for: the failed write takes the rest of its
    /// transaction with it.
    func testAFailedWriteRollsBackTheTransactionItIsIn() throws {
        let database = try makeDatabase()
        database.faults.arm(table: "tags")

        assertInjected(try database.transaction {
            try database.run("INSERT INTO notes (body) VALUES ('x')")
            try database.run("INSERT INTO tags (name) VALUES ('x')")
        }, table: "tags")

        XCTAssertEqual(try count("notes", in: database), 0)
        XCTAssertEqual(try count("tags", in: database), 0)
    }

    // MARK: - The launch switch

    /// The launch argument's switch is one for the process: with two stores
    /// open on a file, the write fails once, not once per store.
    func testTheProcessSwitchIsSpentByWhicheverConnectionWritesFirst() throws {
        let first = try makeDatabase()
        let second = try makeDatabase()
        let launch = SQLiteFaultSwitch(table: "notes")
        first.faults.shared = launch
        second.faults.shared = launch

        assertInjected(try second.run("INSERT INTO notes (body) VALUES ('refused')"), table: "notes")
        try first.run("INSERT INTO notes (body) VALUES ('first')")
        try second.run("INSERT INTO notes (body) VALUES ('second')")

        XCTAssertEqual(try first.rows("SELECT body FROM notes ORDER BY id").map { $0.string(0) }, ["first", "second"])
    }

    func testTheLaunchArgumentNamesTheTable() {
        XCTAssertEqual(SQLiteFaultSwitch.table(in: ["Cabalmail", "-CabalmailFailNextWrite", "pending"]), "pending")
        XCTAssertEqual(
            SQLiteFaultSwitch.table(in: ["Cabalmail", "-other", "1", "-CabalmailFailNextWrite", "items", "-more"]),
            "items")
        XCTAssertNil(SQLiteFaultSwitch.table(in: ["Cabalmail"]))
        XCTAssertNil(SQLiteFaultSwitch.table(in: ["Cabalmail", "-CabalmailFailNextWrite"]), "no table named")
        XCTAssertNil(SQLiteFaultSwitch.table(in: ["Cabalmail", "-CabalmailFailNextWrite", "-other"]),
                     "the next argument is another flag, not a table")
        XCTAssertNil(SQLiteFaultSwitch.table(in: ["Cabalmail", "-CabalmailFailNextWrite", ""]))
    }

    /// A test process is launched without the argument, so the switch every
    /// connection answers to by default is not armed.
    func testAnUnarmedProcessSwitchFailsNothing() throws {
        XCTAssertNil(SQLiteFaultSwitch.table(in: ProcessInfo.processInfo.arguments))
        let database = try makeDatabase()

        try database.run("INSERT INTO notes (body) VALUES ('x')")

        XCTAssertEqual(try count("notes", in: database), 1)
    }

    // MARK: - Through a store

    /// The soak's demonstration of #1956, as a test: with the queue's next
    /// write failed, marking an item read leaves it unread and queues
    /// nothing, and the mark made after that goes through.
    func testAFailedQueueWriteLeavesAFeedItemUnreadAndNothingQueued() async throws {
        let store = try RssStore(directory: directory)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        try await store.upsertItems([
            RssItem(feedId: "f1", itemId: "a", sortKey: "a", publishedAt: "2026-01-02T00:00:00Z"),
        ])
        await store.failNextWriteForTests(to: "pending")

        do {
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            XCTFail("the failed queue write should fail the mark")
        } catch {
            guard case CabalmailError.storage = error else {
                return XCTFail("the store hands on a storage error, got \(error)")
            }
        }

        let refused = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(refused?.isRead, false, "no local read without its push")
        let queuedAfterTheFailure = try await store.pendingCount()
        XCTAssertEqual(queuedAfterTheFailure, 0)

        try await store.setRead(feedId: "f1", sortKey: "a", true)
        let marked = try await store.item(feedId: "f1", sortKey: "a")
        XCTAssertEqual(marked?.isRead, true)
        let queued = try await store.pendingMutations().map(\.kind)
        XCTAssertEqual(queued, [.read])
    }
}

private extension RssStore {
    /// Arms this store's connection to fail its next write to `table`.
    func failNextWriteForTests(to table: String) {
        database.faults.arm(table: table)
    }
}
#endif
