import XCTest
@testable import CabalmailKit

final class MessageBodyCacheTests: XCTestCase {
    private var tempDir: URL!
    private var cache: MessageBodyCache!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-body-cache-\(UUID().uuidString)")
        cache = try MessageBodyCache(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - clearAll()

    func testClearAllDropsEveryBody() async throws {
        try await cache.store(folder: "INBOX", uidValidity: 100, uid: 1, bytes: Data("a".utf8))
        try await cache.store(folder: "Archive", uidValidity: 100, uid: 2, bytes: Data("b".utf8))
        try await cache.clearAll()
        let inbox = await cache.fetch(folder: "INBOX", uidValidity: 100, uid: 1)
        let archive = await cache.fetch(folder: "Archive", uidValidity: 100, uid: 2)
        XCTAssertNil(inbox)
        XCTAssertNil(archive)
    }

    /// The cache must stay usable after a clear: the next store should land
    /// on disk rather than throw because the directory went missing.
    func testClearAllLeavesCacheUsable() async throws {
        try await cache.store(folder: "INBOX", uidValidity: 100, uid: 1, bytes: Data("a".utf8))
        try await cache.clearAll()
        try await cache.store(folder: "INBOX", uidValidity: 100, uid: 9, bytes: Data("z".utf8))
        let body = await cache.fetch(folder: "INBOX", uidValidity: 100, uid: 9)
        XCTAssertEqual(body, Data("z".utf8))
    }
}
