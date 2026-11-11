import XCTest
@testable import CabalmailKit

/// `SQLiteSetAside`: a database file moved out of its store's way with
/// everything committed to it, whether SQLite had copied that into the main
/// file yet or it was still in the write-ahead log.
final class SQLiteSetAsideTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("store.sqlite") }
    private var aside: SQLiteSetAside { SQLiteSetAside(database: database) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-set-aside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func exists(_ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: database.path + suffix)
    }

    private func bodies(in file: URL) throws -> [String] {
        let copy = try SQLiteDatabase(path: file.path, existing: true)
        defer { copy.close() }
        return try copy.rows("SELECT body FROM notes ORDER BY rowid").map { $0.string(0) }
    }

    private func size(of path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    /// A store in WAL mode that never checkpoints by itself, so what it
    /// writes stays in the `-wal` file until something folds it in.
    private func openWriter(at path: String) throws -> SQLiteDatabase {
        let writer = try SQLiteDatabase(path: path)
        try writer.exec("PRAGMA journal_mode = WAL")
        try writer.exec("PRAGMA wal_autocheckpoint = 0")
        try writer.exec("CREATE TABLE IF NOT EXISTS notes (body TEXT)")
        return writer
    }

    /// What a process that died mid-session leaves: the main file and a
    /// write-ahead log holding a row that was never copied into it.
    func testAFileIsMovedWithWhatWasOnlyInItsWriteAheadLog() throws {
        let elsewhere = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let source = elsewhere.appendingPathComponent("store.sqlite").path
        do {
            let writer = try openWriter(at: source)
            defer { writer.close() }
            try writer.run("INSERT INTO notes (body) VALUES ('unsent')")
            // Copied while the writer is open, before its close folds the log in.
            try FileManager.default.copyItem(atPath: source, toPath: database.path)
            try FileManager.default.copyItem(atPath: source + "-wal", toPath: database.path + "-wal")
        }
        XCTAssertGreaterThan(size(of: database.path + "-wal"), 0, "the row is in the log")

        XCTAssertTrue(aside.setAside(reason: "test"))

        let file = try XCTUnwrap(aside.files().first)
        XCTAssertEqual(try bodies(in: file), ["unsent"])
        XCTAssertEqual([exists(""), exists("-wal"), exists("-shm")], [false, false, false],
                       "nothing is left for the file that takes this one's place to read as its own")
    }

    /// The same when the log cannot be folded in first: another connection
    /// reading from before the last write holds the log open, so the log is
    /// moved as it is, under the name SQLite looks for beside the copy.
    /// (While such a connection lives the copy cannot be opened at all,
    /// which a store reads as "not yet" and tries again at its next open.)
    func testALogThatCannotBeFoldedInIsMovedBesideTheFile() throws {
        let writer = try openWriter(at: database.path)
        try writer.run("INSERT INTO notes (body) VALUES ('before the reader')")
        let reader = try SQLiteDatabase(path: database.path, existing: true)
        try reader.exec("BEGIN")
        XCTAssertEqual(try reader.rows("SELECT COUNT(*) FROM notes").first?.int(0), 1)
        try writer.run("INSERT INTO notes (body) VALUES ('after the reader')")
        let logSize = size(of: database.path + "-wal")

        XCTAssertTrue(aside.setAside(reason: "test"))

        let file = try XCTUnwrap(aside.files().first)
        XCTAssertEqual(size(of: file.path + "-wal"), logSize, "the log went with the file, whole")
        XCTAssertEqual([exists(""), exists("-wal"), exists("-shm")], [false, false, false])
        reader.close()
        writer.close()
        XCTAssertEqual(try bodies(in: file), ["before the reader", "after the reader"])
    }

    func testNothingToSetAsideIsNotAFailure() {
        XCTAssertTrue(aside.setAside(reason: "test"))
        XCTAssertEqual(aside.files(), [])
    }

    func testFilesAreListedOldestFirstWithoutTheirSideFiles() throws {
        try FileManager.default.createDirectory(at: aside.directory, withIntermediateDirectories: true)
        let earlier = SQLiteSetAside.name(for: database, at: Date(timeIntervalSince1970: 1_700_000_000))
        let later = SQLiteSetAside.name(for: database, at: Date(timeIntervalSince1970: 1_800_000_000.5))
        for name in [later, earlier, earlier + "-wal", earlier + "-shm", "notes.txt"] {
            try Data([0x00]).write(to: aside.directory.appendingPathComponent(name))
        }

        XCTAssertEqual(aside.files().map(\.lastPathComponent), [earlier, later])
        XCTAssertTrue(earlier.hasPrefix("store-1700000000000-"))
        XCTAssertTrue(later.hasPrefix("store-1800000000500-"))
        XCTAssertTrue(earlier.hasSuffix(".sqlite"))

        aside.remove(aside.directory.appendingPathComponent(earlier))

        let left = try FileManager.default.contentsOfDirectory(atPath: aside.directory.path).sorted()
        XCTAssertEqual(left, [later, "notes.txt"].sorted(), "a file goes with its side files, and only those")
    }

    func testTwoFilesSetAsideAtTheSameMomentGetDifferentNames() {
        let moment = Date()
        XCTAssertNotEqual(SQLiteSetAside.name(for: database, at: moment),
                          SQLiteSetAside.name(for: database, at: moment))
    }
}
