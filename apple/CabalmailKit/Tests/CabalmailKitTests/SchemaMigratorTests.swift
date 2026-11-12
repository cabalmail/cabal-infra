import XCTest
@testable import CabalmailKit

/// `SchemaMigrator`: ordered steps on `user_version`, each atomic with its
/// version write, and a newer file handled the way the caller chose.
final class SchemaMigratorTests: XCTestCase {
    private var directory: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-migrator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDown() {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Refused: Error {}

    private static let createNotes = SchemaMigrator.Step.sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
    private static let addPinned = SchemaMigrator.Step.sql("ALTER TABLE notes ADD COLUMN pinned INTEGER DEFAULT 0")
    /// A step in code: what SQL alone cannot do.
    private static let upperCaseBodies = SchemaMigrator.Step { database in
        for row in try database.rows("SELECT id, body FROM notes") {
            try database.run("UPDATE notes SET body = ? WHERE id = ?",
                             [.init(row.string(1).uppercased()), .init(row.int(0))])
        }
    }

    private func migrator(_ steps: [SchemaMigrator.Step]) -> SchemaMigrator {
        SchemaMigrator(name: "test.sqlite", steps: steps)
    }

    private func columns(of table: String) throws -> [String] {
        try database.rows("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.init(table)]).map { $0.string(0) }
    }

    func testAnEmptyFileRunsEveryStepInOrder() throws {
        let all = migrator([Self.createNotes, Self.addPinned])
        XCTAssertEqual(all.version, 2)

        try all.migrate(database, newerSchema: .refuse)

        XCTAssertEqual(try database.userVersion(), 2)
        XCTAssertEqual(try columns(of: "notes"), ["id", "body", "pinned"])
    }

    func testAFilePartWayThroughRunsOnlyTheStepsItLacks() throws {
        try migrator([Self.createNotes]).migrate(database, newerSchema: .refuse)
        try database.run("INSERT INTO notes (body) VALUES ('kept')")

        // Were step 1 run again, its CREATE would fail on the existing table.
        try migrator([Self.createNotes, Self.addPinned, Self.upperCaseBodies])
            .migrate(database, newerSchema: .refuse)

        XCTAssertEqual(try database.userVersion(), 3)
        XCTAssertEqual(try database.rows("SELECT body, pinned FROM notes").map { "\($0.string(0)) \($0.int(1))" },
                       ["KEPT 0"])
    }

    func testAFileAlreadyAtTheLastStepIsLeftAlone() throws {
        let all = migrator([Self.createNotes, Self.addPinned])
        try all.migrate(database, newerSchema: .refuse)

        try all.migrate(database, newerSchema: .refuse)

        XCTAssertEqual(try database.userVersion(), 2)
    }

    /// A step that fails part-way leaves nothing of itself behind: its own
    /// earlier statements are undone and the version stays where the last
    /// good step left it, so the next open can run the step again.
    func testAStepThatThrowsIsRolledBackWithItsVersion() throws {
        let failing = SchemaMigrator.Step { database in
            try database.exec("ALTER TABLE notes ADD COLUMN pinned INTEGER DEFAULT 0")
            try database.run("INSERT INTO notes (body) VALUES ('half done')")
            throw Refused()
        }

        XCTAssertThrowsError(try migrator([Self.createNotes, failing, Self.upperCaseBodies])
            .migrate(database, newerSchema: .refuse)) { error in
                XCTAssertTrue(error is Refused, "the step's own error reaches the caller, got \(error)")
            }

        XCTAssertEqual(try database.userVersion(), 1, "the good step stays; the failed one and those after it do not")
        XCTAssertEqual(try columns(of: "notes"), ["id", "body"])
        XCTAssertEqual(try database.rows("SELECT COUNT(*) FROM notes").first?.int(0), 0)

        // The same file migrates cleanly once the step works.
        try migrator([Self.createNotes, Self.addPinned]).migrate(database, newerSchema: .refuse)
        XCTAssertEqual(try database.userVersion(), 2)
        XCTAssertEqual(try columns(of: "notes"), ["id", "body", "pinned"])
    }

    func testFailingSQLInAStepIsRolledBackToo() throws {
        let failing = SchemaMigrator.Step.sql("""
            ALTER TABLE notes ADD COLUMN pinned INTEGER DEFAULT 0;
            ALTER TABLE notes ADD COLUMN pinned INTEGER DEFAULT 0;
            """)

        XCTAssertThrowsError(try migrator([Self.createNotes, failing]).migrate(database, newerSchema: .refuse)) {
            guard case CabalmailError.storage = $0 else { return XCTFail("a storage error, got \($0)") }
        }

        XCTAssertEqual(try database.userVersion(), 1)
        XCTAssertEqual(try columns(of: "notes"), ["id", "body"])
    }

    /// A downgrade: a newer build wrote the file. Refused, the file is left
    /// exactly as it was, for the caller to recover from.
    func testANewerSchemaIsRefusedAndTheFileIsUntouched() throws {
        try migrator([Self.createNotes, Self.addPinned]).migrate(database, newerSchema: .refuse)
        try database.setUserVersion(5)
        let ran = Flag()
        let older = migrator([Self.createNotes, SchemaMigrator.Step { _ in ran.set() }])

        XCTAssertThrowsError(try older.migrate(database, newerSchema: .refuse)) { error in
            guard case CabalmailError.storage(let detail) = error else {
                return XCTFail("a newer schema is a storage error, got \(error)")
            }
            XCTAssertEqual(detail, "test.sqlite schema 5 is newer than this build's 2")
        }

        XCTAssertFalse(ran.isSet)
        XCTAssertEqual(try database.userVersion(), 5)
        XCTAssertEqual(try columns(of: "notes"), ["id", "body", "pinned"])
    }

    /// The other policy, for a file whose schema only grows: opened as it
    /// is, at the newer build's version, with no step run.
    func testANewerSchemaCanBeUsedAsItIs() throws {
        try migrator([Self.createNotes, Self.addPinned]).migrate(database, newerSchema: .refuse)
        try database.setUserVersion(5)
        let ran = Flag()
        let older = migrator([Self.createNotes, SchemaMigrator.Step { _ in ran.set() }])

        try older.migrate(database, newerSchema: .useAsIs)

        XCTAssertFalse(ran.isSet)
        XCTAssertEqual(try database.userVersion(), 5)
        XCTAssertEqual(try columns(of: "notes"), ["id", "body", "pinned"])
    }

    /// `RssStore` is on the runner, one step per version of its schema.
    func testTheFeedStoreMigratesThroughTheRunnerAtSchemaSeven() throws {
        XCTAssertEqual(RssStore.migrator.version, 7)
        XCTAssertEqual(RssStore.schemaVersion, 7)

        try RssStore.migrator.migrate(database, newerSchema: .refuse)

        XCTAssertEqual(try database.userVersion(), 7)
        XCTAssertTrue(try columns(of: "folders").contains("ordering_mode"), "version 6 ran")
        XCTAssertTrue(try columns(of: "items").contains("flags"), "the last step, version 7, ran")
        XCTAssertTrue(try columns(of: "pending").contains("slot"))
    }
}

/// Whether a `@Sendable` step ran.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
