import XCTest
@testable import CabalmailKit

/// The store keeps the per-subscription web-storage identifiers the app
/// layer must drop: departed ones after any catalog sync, and all of them
/// on sign-out.
final class RssStoreWebStorageTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-webstorage-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sub(_ id: String, uuid: String) -> RssSubscription {
        RssSubscription(subscriptionId: id, feedId: "f-\(id)", dataStoreUuid: uuid)
    }

    /// A subscription removed by a sync whose caller discards the diff (the
    /// poller's `syncAll`) is still handed over - once - on the next take,
    /// and a later sync cannot lose it.
    func testDepartedUuidsSurviveADiscardedDiffAndAreTakenOnce() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [
            sub("s1", uuid: "u1"), sub("s2", uuid: "u2"), sub("s3", uuid: ""),
        ]))
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [sub("s1", uuid: "u1")]))
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [sub("s1", uuid: "u1")]))
        let taken = try await store.takeDepartedDataStoreUuids()
        XCTAssertEqual(taken, ["u2"])
        let again = try await store.takeDepartedDataStoreUuids()
        XCTAssertEqual(again, [])
    }

    /// Sign-out reads every identifier - subscribed and departed-but-not-
    /// yet-dropped - before `clear()` forgets them all.
    func testAllUuidsCoverSubscribedAndDepartedUntilCleared() async throws {
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [
            sub("s1", uuid: "u1"), sub("s2", uuid: "u2"),
        ]))
        _ = try await store.replaceCatalog(RssCatalog(folders: [], subscriptions: [sub("s1", uuid: "u1")]))
        let all = try await store.allDataStoreUuids()
        XCTAssertEqual(all, ["u1", "u2"])
        try await store.clear()
        let afterClear = try await store.allDataStoreUuids()
        XCTAssertEqual(afterClear, [])
        let departed = try await store.takeDepartedDataStoreUuids()
        XCTAssertEqual(departed, [])
    }
}
