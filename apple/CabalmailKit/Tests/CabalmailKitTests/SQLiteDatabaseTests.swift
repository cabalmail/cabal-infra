import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// `SQLiteDatabase`: the write transaction, BLOB binds, the `user_version`
/// pragma, and every failure arriving as `CabalmailError.storage`.
final class SQLiteDatabaseTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("test.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: path)
        try database.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        return database
    }

    private func bodies(_ database: SQLiteDatabase) throws -> [String] {
        try database.rows("SELECT body FROM notes ORDER BY id").map { $0.string(0) }
    }

    private struct Refused: Error {}

    // MARK: - Transactions

    func testATransactionCommitsWhatItsBodyWroteAndReturnsItsValue() throws {
        let database = try makeDatabase()

        let count = try database.transaction { () -> Int in
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("one")])
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("two")])
            return try database.rows("SELECT COUNT(*) FROM notes").first?.int(0) ?? 0
        }

        XCTAssertEqual(count, 2)
        // A second connection sees only what was committed.
        XCTAssertEqual(try bodies(try SQLiteDatabase(path: path)), ["one", "two"])
    }

    func testAThrowingBodyRollsBackEveryWriteAndRethrows() throws {
        let database = try makeDatabase()
        try database.run("INSERT INTO notes (body) VALUES (?)", [.init("kept")])

        XCTAssertThrowsError(try database.transaction {
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("lost")])
            try database.run("DELETE FROM notes WHERE body = ?", [.init("kept")])
            throw Refused()
        }) { error in
            XCTAssertTrue(error is Refused, "the body's own error reaches the caller, got \(error)")
        }

        XCTAssertEqual(try bodies(database), ["kept"])
        // The connection is out of the failed transaction: the next one runs.
        try database.transaction {
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("next")])
        }
        XCTAssertEqual(try bodies(database), ["kept", "next"])
    }

    func testAFailedStatementRollsBackTheStatementsBeforeIt() throws {
        let database = try makeDatabase()

        XCTAssertThrowsError(try database.transaction {
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("lost")])
            try database.run("INSERT INTO notes (body) VALUES (?)", [.null])
        }) { error in
            guard case CabalmailError.storage = error else {
                return XCTFail("a refused statement is a storage error, got \(error)")
            }
        }

        XCTAssertEqual(try bodies(database), [])
    }

    /// The write lock is taken when the transaction starts, not at its first
    /// write: with another connection holding it, the body never runs. A
    /// deferred `BEGIN` would run the body's reads and fail at its write.
    func testATransactionTakesTheWriteLockBeforeItsBodyRuns() throws {
        let database = try makeDatabase()
        let lock = try SQLiteWriteLock(path: path)
        defer { lock.release() }
        var bodyRan = false

        XCTAssertThrowsError(try database.transaction { bodyRan = true }) { error in
            guard case CabalmailError.storage = error else {
                return XCTFail("a busy file is a storage error, got \(error)")
            }
        }

        XCTAssertFalse(bodyRan)
    }

    func testATransactionInsideAnotherThrowsAndTheOuterOneRollsBack() throws {
        let database = try makeDatabase()

        XCTAssertThrowsError(try database.transaction {
            try database.run("INSERT INTO notes (body) VALUES (?)", [.init("outer")])
            try database.transaction {
                try database.run("INSERT INTO notes (body) VALUES (?)", [.init("inner")])
            }
        })

        XCTAssertEqual(try bodies(database), [])
    }

    // MARK: - BLOBs

    func testBlobsRoundTripAndKeepTheirBytes() throws {
        let database = try SQLiteDatabase(path: path)
        try database.exec("CREATE TABLE blobs (id INTEGER PRIMARY KEY, payload BLOB)")
        // Bytes that are not text: a NUL in the middle, and invalid UTF-8.
        let payload = Data([0x00, 0xFF, 0x10, 0x00, 0xC3, 0x28, 0x7F])

        try database.run("INSERT INTO blobs (id, payload) VALUES (1, ?)", [.init(payload)])
        try database.run("INSERT INTO blobs (id, payload) VALUES (2, ?)", [.init(Data())])
        try database.run("INSERT INTO blobs (id, payload) VALUES (3, ?)", [.init(nil as Data?)])

        let rows = try database.rows("SELECT payload, typeof(payload) FROM blobs ORDER BY id")
        XCTAssertEqual(rows.map { $0.data(0) }, [payload, Data(), Data()])
        XCTAssertEqual(rows.map { $0.string(1) }, ["blob", "blob", "null"],
                       "an empty blob stays a blob; only a nil one is NULL")
        XCTAssertEqual(rows.map { $0.isNull(0) }, [false, false, true])
    }

    func testABlobCanBeMatchedByABoundBlob() throws {
        let database = try SQLiteDatabase(path: path)
        try database.exec("CREATE TABLE blobs (id INTEGER PRIMARY KEY, payload BLOB)")
        let wanted = Data([0xDE, 0xAD, 0x00, 0xBE, 0xEF])
        try database.run("INSERT INTO blobs (id, payload) VALUES (1, ?), (2, ?)",
                         [.init(Data([0x01])), .init(wanted)])

        let ids = try database.rows("SELECT id FROM blobs WHERE payload = ?", [.init(wanted)]).map { $0.int(0) }

        XCTAssertEqual(ids, [2])
    }

    // MARK: - user_version

    func testUserVersionRoundTripsAndStartsAtZero() throws {
        let database = try SQLiteDatabase(path: path)
        XCTAssertEqual(try database.userVersion(), 0)

        try database.setUserVersion(4)

        XCTAssertEqual(try SQLiteDatabase(path: path).userVersion(), 4)
    }

    /// Both used to swallow the failure: the read answered 0, which told a
    /// migration to run every step again, and the write did nothing.
    func testUserVersionThrowsWhenItCannotBeReadOrWritten() throws {
        let database = try SQLiteDatabase(path: path)
        database.close()

        XCTAssertThrowsError(try database.userVersion()) { error in
            guard case CabalmailError.storage = error else {
                return XCTFail("a failed read is a storage error, got \(error)")
            }
        }
        XCTAssertThrowsError(try database.setUserVersion(2)) { error in
            guard case CabalmailError.storage = error else {
                return XCTFail("a failed write is a storage error, got \(error)")
            }
        }
    }

    // MARK: - Errors

    func testEveryKindOfFailureIsAStorageErrorCarryingSQLitesCode() throws {
        let database = try makeDatabase()
        let failures: [() throws -> Void] = [
            { try database.exec("CREATE TABLE notes (id INTEGER)") },
            { try database.run("INSERT INTO missing (body) VALUES ('x')") },
            { _ = try database.rows("SELECT nothing FROM notes") },
            { try database.run("INSERT INTO notes (body) VALUES (?)", [.null]) },
            { _ = try SQLiteDatabase(path: self.directory.appendingPathComponent("no/such/dir/x.sqlite").path) },
        ]

        for (index, failure) in failures.enumerated() {
            XCTAssertThrowsError(try failure(), "failure \(index)") { error in
                guard case CabalmailError.storage(let detail) = error else {
                    return XCTFail("failure \(index) is a storage error, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("SQLite error "), "failure \(index) names SQLite's code: \(detail)")
            }
        }
    }
}
