import XCTest
@testable import CabalmailKit

/// `CabalmailClient.rawMessage(folder:uid:)`, the one path by which the
/// reader opens a message and the list drags one out. It protects two fixes:
///
/// - #1810: offline, with no envelope snapshot for the folder, a body already
///   in the cache still opens, looked up under the UIDVALIDITY the folder last
///   reported. That saved value is a read key only: on a miss the STATUS
///   error stands and nothing is fetched or stored under it.
/// - #1811: a failed body-cache write does not fail an open whose bytes
///   arrived.
final class RawMessageTests: XCTestCase {
    private let uid: UInt32 = 7
    private let bytes = Data("Subject: hello\r\n\r\nbody".utf8)
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    /// The folder-state cache gets a directory so it saves what STATUS said.
    private func makeClient(_ imap: FakeImapClient) async throws -> CabalmailClient {
        let folderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-message-folders-\(UUID().uuidString)")
        roots.append(folderRoot)
        let client = try TestFixtures.makeClient(
            imap: imap, folderStateCache: FolderStateCache(directory: folderRoot)
        )
        roots.append(await client.bodyCache.directory.deletingLastPathComponent())
        return client
    }

    private func seedSnapshot(_ client: CabalmailClient, uidValidity: UInt32) async throws {
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: uidValidity,
                uidNext: uid + 1,
                envelopes: [uid: TestFixtures.makeEnvelope(uid: uid)]
            ),
            for: "INBOX"
        )
    }

    private func saveStatus(_ client: CabalmailClient, uidValidity: UInt32) async {
        let generation = await client.folderStateCache.generation
        await client.folderStateCache.recordStatus(
            FolderStatus(messages: 1, uidValidity: uidValidity), for: "INBOX", ifUnchangedSince: generation
        )
    }

    func testASnapshotKeysTheCacheAndAHitMakesNoWireCall() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)
        try await seedSnapshot(client, uidValidity: 42)
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 42, uid: uid, bytes: bytes)

        let result = try await client.rawMessage(folder: "INBOX", uid: uid)

        XCTAssertEqual(result, bytes)
        let statusCalls = await imap.statusCalls
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(statusCalls.isEmpty)
        XCTAssertTrue(fetches.isEmpty)
    }

    func testWithoutASnapshotStatusKeysTheFetchAndTheStore() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(messages: 1, uidValidity: 9))])
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(bytes)])
        let client = try await makeClient(imap)

        let result = try await client.rawMessage(folder: "INBOX", uid: uid)

        XCTAssertEqual(result, bytes)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.map(\.folder), ["INBOX"])
        XCTAssertEqual(fetches.map(\.uid), [uid])
        let cached = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 9, uid: uid)
        XCTAssertEqual(cached, bytes)
    }

    /// #1810: before, the STATUS failure ended the open without a look in
    /// the cache.
    func testOfflineWithoutASnapshotACachedBodyOpensUnderTheSavedValidity() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await makeClient(imap)
        await saveStatus(client, uidValidity: 42)
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 42, uid: uid, bytes: bytes)

        let result = try await client.rawMessage(folder: "INBOX", uid: uid)

        XCTAssertEqual(result, bytes)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    func testOfflineWithASavedValidityButNoCachedBodyKeepsTheStatusError() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await makeClient(imap)
        await saveStatus(client, uidValidity: 42)
        // Cached under another validity: the saved key must not find it.
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 41, uid: uid, bytes: bytes)

        await assertNetworkOffline { try await client.rawMessage(folder: "INBOX", uid: uid) }
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty, "nothing is fetched under the saved value")
    }

    func testOfflineWithNoSavedStatusKeepsTheStatusError() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await makeClient(imap)
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 42, uid: uid, bytes: bytes)

        await assertNetworkOffline { try await client.rawMessage(folder: "INBOX", uid: uid) }
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    /// #1811: before, the cache's file-system error replaced the bytes.
    func testAFailedCacheWriteStillReturnsTheFetchedBytes() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(bytes)])
        let client = try await makeClient(imap)
        try await seedSnapshot(client, uidValidity: 42)
        // A plain file where the cache's directory should be: every store fails.
        let cacheRoot = await client.bodyCache.directory
        try FileManager.default.removeItem(at: cacheRoot)
        try Data().write(to: cacheRoot)

        let result = try await client.rawMessage(folder: "INBOX", uid: uid)

        XCTAssertEqual(result, bytes)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    private func assertNetworkOffline(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ call: () async throws -> Data
    ) async {
        do {
            _ = try await call()
            XCTFail("expected the STATUS failure", file: file, line: line)
        } catch CabalmailError.network(let detail) {
            XCTAssertEqual(detail, "offline", file: file, line: line)
        } catch {
            XCTFail("expected .network(\"offline\"), got \(error)", file: file, line: line)
        }
    }
}
