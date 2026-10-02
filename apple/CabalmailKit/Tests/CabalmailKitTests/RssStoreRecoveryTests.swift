import XCTest
@testable import CabalmailKit

/// `RssStore.openRecovering`: a feed cache that cannot be opened or
/// migrated is rebuilt, never fatal to the client that owns it.
final class RssStoreRecoveryTests: XCTestCase {
    /// A store an older build left half-way through v4 (the first ALTER
    /// applied, `user_version` still 3) fails to migrate - the rerun hits
    /// "duplicate column" - so `openRecovering` deletes it and opens a
    /// fresh, fully migrated one instead of failing the client.
    func testHalfAppliedV4MigrationIsRecreated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-store-half-v4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: dir.appendingPathComponent("rss.sqlite").path)
            try database.exec(Schema.version1)
            try database.exec(Schema.version2)
            try database.exec(Schema.version3)
            try database.exec("ALTER TABLE subscriptions ADD COLUMN default_filter TEXT NOT NULL DEFAULT 'unread'")
            try database.run("INSERT INTO subscriptions (subscription_id, feed_id) VALUES ('old', 'f0')", [])
            database.userVersion = 3
        }
        XCTAssertThrowsError(try RssStore(directory: dir))
        let recovered = try XCTUnwrap(RssStore.openRecovering(directory: dir))
        let leftovers = try await recovered.subscriptions()
        XCTAssertEqual(leftovers, [], "the cache starts empty; the next sync repopulates it")
        _ = try await recovered.replaceCatalog(RssCatalog(
            folders: [RssFolder(folderId: "fo", name: "Tech", defaultFilter: .all)],
            subscriptions: [RssSubscription(subscriptionId: "s1", feedId: "f1", folderId: "fo")]))
        let folder = try await recovered.folder(id: "fo")
        XCTAssertEqual(folder?.defaultFilter, .all, "v4 is fully applied")
        let reopened = try SQLiteDatabase(path: dir.appendingPathComponent("rss.sqlite").path)
        XCTAssertEqual(reopened.userVersion, RssStore.schemaVersion)
    }

    /// A file that is not a database at all is replaced, not fatal.
    func testCorruptFileIsRecreated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-store-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 8192).write(to: dir.appendingPathComponent("rss.sqlite"))
        XCTAssertThrowsError(try RssStore(directory: dir))
        let recovered = try XCTUnwrap(RssStore.openRecovering(directory: dir))
        try await recovered.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        let loaded = try await recovered.subscription(id: "s1")
        XCTAssertEqual(loaded?.feedId, "f1")
    }

    /// A file from a newer build (a downgrade) is recreated at this
    /// build's schema rather than read with columns it does not know.
    func testNewerSchemaIsRecreated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-store-newer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try RssStore(directory: dir)
        do {
            let database = try SQLiteDatabase(path: dir.appendingPathComponent("rss.sqlite").path)
            database.userVersion = RssStore.schemaVersion + 1
        }
        XCTAssertThrowsError(try RssStore(directory: dir))
        XCTAssertNotNil(RssStore.openRecovering(directory: dir))
        let reopened = try SQLiteDatabase(path: dir.appendingPathComponent("rss.sqlite").path)
        XCTAssertEqual(reopened.userVersion, RssStore.schemaVersion)
    }
}
