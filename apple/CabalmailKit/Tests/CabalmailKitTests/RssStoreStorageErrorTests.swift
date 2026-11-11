import XCTest
@testable import CabalmailKit

/// A feed store failure reaches its caller as `CabalmailError.storage`, the
/// Kit's error for "this device's storage failed", and never as a raw SQLite
/// error: the feed list and sidebar show an error's `localizedDescription`,
/// and for a type that has none the system prints "The operation couldn't
/// be completed" and the type's name.
final class RssStoreStorageErrorTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-storage-error-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func assertStorage(_ error: Error, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case CabalmailError.storage = error else {
            return XCTFail("\(what) is a storage error, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(error.localizedDescription.hasPrefix("Couldn't read or save data on this device. SQLite error "),
                      "\(what) reads as a sentence: \(error.localizedDescription)", file: file, line: line)
    }

    func testAWriteAReadAndATransactionOnAClosedStoreAreStorageErrors() async throws {
        let store = try RssStore(directory: directory)
        try await store.retire()

        do {
            try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
            XCTFail("a retired store took a write")
        } catch {
            assertStorage(error, "a write")
        }
        do {
            _ = try await store.subscriptions()
            XCTFail("a retired store answered a read")
        } catch {
            assertStorage(error, "a read")
        }
        do {
            try await store.setRead(feedId: "f1", sortKey: "a", true)
            XCTFail("a retired store took a mark")
        } catch {
            assertStorage(error, "a transaction")
        }
    }

    func testAWriteSQLiteRefusesIsAStorageError() async throws {
        let store = try RssStore(directory: directory)
        try await store.execForTests("""
            CREATE TRIGGER refuse_folders BEFORE INSERT ON folders
            BEGIN SELECT RAISE(ABORT, 'database is full'); END
            """)

        do {
            try await store.upsertFolder(RssFolder(folderId: "fo", name: "Tech"))
            XCTFail("the refused write should throw")
        } catch {
            assertStorage(error, "a refused write")
        }
    }

    /// A file from a newer build fails the open with a storage error that
    /// says so, which `openRecovering` then recovers from.
    func testAStoreFromANewerBuildFailsToOpenWithAStorageError() throws {
        _ = try RssStore(directory: directory)
        do {
            let database = try SQLiteDatabase(path: directory.appendingPathComponent("rss.sqlite").path)
            try database.setUserVersion(RssStore.schemaVersion + 1)
        }

        XCTAssertThrowsError(try RssStore(directory: directory)) { error in
            XCTAssertEqual(error as? CabalmailError,
                           .storage("rss.sqlite schema 8 is newer than this build's 7"))
        }
    }
}

private extension RssStore {
    /// Raw SQL against the store's file, for setting up a failure.
    func execForTests(_ sql: String) throws {
        try database.exec(sql)
    }
}
