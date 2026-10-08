import XCTest
@testable import CabalmailKit

/// `CabalmailClient.forgetRemovedMessages(_:)`, the one place a confirmed
/// removal leaves the offline caches. It protects #1869: a removal from
/// global search, whose list has no UIDVALIDITY of its own, left the message
/// in its folder's envelope and body caches. Each ref is now forgotten in its
/// own folder, under that folder's own UIDVALIDITY.
final class ForgetRemovedMessagesTests: XCTestCase {
    private let bytes = Data("Subject: hello\r\n\r\nbody".utf8)
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func makeClient(_ imap: FakeImapClient) async throws -> CabalmailClient {
        let folderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forget-removed-folders-\(UUID().uuidString)")
        roots.append(folderRoot)
        let client = try TestFixtures.makeClient(
            imap: imap, folderStateCache: FolderStateCache(directory: folderRoot)
        )
        roots.append(await client.bodyCache.directory.deletingLastPathComponent())
        return client
    }

    private func seedSnapshot(
        _ client: CabalmailClient, folder: String, uidValidity: UInt32, uids: [UInt32]
    ) async throws {
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: uidValidity,
                uidNext: (uids.max() ?? 0) + 1,
                envelopes: Dictionary(uniqueKeysWithValues: uids.map { ($0, TestFixtures.makeEnvelope(uid: $0)) })
            ),
            for: folder
        )
    }

    private func saveStatus(_ client: CabalmailClient, folder: String, uidValidity: UInt32) async {
        let generation = await client.folderStateCache.generation
        await client.folderStateCache.recordStatus(
            FolderStatus(messages: 1, uidValidity: uidValidity), for: folder, ifUnchangedSince: generation
        )
    }

    private func cachedUIDs(_ client: CabalmailClient, folder: String) async -> Set<UInt32> {
        Set(await client.envelopeCache.snapshot(for: folder)?.envelopes.keys.map { $0 } ?? [])
    }

    private func body(_ client: CabalmailClient, folder: String, uidValidity: UInt32, uid: UInt32) async -> Data? {
        await client.bodyCache.fetch(folder: folder, uidValidity: uidValidity, uid: uid)
    }

    /// The issue's case: refs from two folders, as global search returns
    /// them, each forgotten in its own folder under its own UIDVALIDITY.
    func testEachRefIsForgottenInItsOwnFolderUnderItsOwnValidity() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)
        try await seedSnapshot(client, folder: "INBOX", uidValidity: 42, uids: [3, 2])
        try await seedSnapshot(client, folder: "Work", uidValidity: 7, uids: [5, 4])
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 42, uid: 3, bytes: bytes)
        try await client.bodyCache.store(folder: "Work", uidValidity: 7, uid: 5, bytes: bytes)
        try await client.bodyCache.store(folder: "Work", uidValidity: 7, uid: 4, bytes: bytes)

        await client.forgetRemovedMessages([
            MessageRef(folder: "INBOX", uid: 3), MessageRef(folder: "Work", uid: 5)
        ])

        let inboxRows = await cachedUIDs(client, folder: "INBOX")
        let workRows = await cachedUIDs(client, folder: "Work")
        XCTAssertEqual(inboxRows, [2])
        XCTAssertEqual(workRows, [4])
        let inboxBody = await body(client, folder: "INBOX", uidValidity: 42, uid: 3)
        let workBody = await body(client, folder: "Work", uidValidity: 7, uid: 5)
        let keptBody = await body(client, folder: "Work", uidValidity: 7, uid: 4)
        XCTAssertNil(inboxBody)
        XCTAssertNil(workBody)
        XCTAssertEqual(keptBody, bytes, "the message still there keeps its body")
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty, "the snapshots answered")
    }

    func testARefsOwnValidityKeysItsBodyWithNoWireCall() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)
        try await client.bodyCache.store(folder: "Work", uidValidity: 9, uid: 5, bytes: bytes)

        await client.forgetRemovedMessages([MessageRef(folder: "Work", uid: 5, uidValidity: 9)])

        let left = await body(client, folder: "Work", uidValidity: 9, uid: 5)
        XCTAssertNil(left)
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty)
    }

    func testWithNoSnapshotTheSavedValidityKeysTheBody() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)
        await saveStatus(client, folder: "Work", uidValidity: 11)
        try await client.bodyCache.store(folder: "Work", uidValidity: 11, uid: 5, bytes: bytes)

        await client.forgetRemovedMessages([MessageRef(folder: "Work", uid: 5)])

        let left = await body(client, folder: "Work", uidValidity: 11, uid: 5)
        XCTAssertNil(left)
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty)
    }

    /// With nothing saved, a STATUS answers once for the folder.
    func testWithNothingSavedOneStatusKeysTheFolder() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(messages: 1, uidValidity: 13))])
        let client = try await makeClient(imap)
        try await client.bodyCache.store(folder: "Work", uidValidity: 13, uid: 5, bytes: bytes)
        try await client.bodyCache.store(folder: "Work", uidValidity: 13, uid: 4, bytes: bytes)

        await client.forgetRemovedMessages([MessageRef(folder: "Work", uid: 5), MessageRef(folder: "Work", uid: 4)])

        let five = await body(client, folder: "Work", uidValidity: 13, uid: 5)
        let four = await body(client, folder: "Work", uidValidity: 13, uid: 4)
        XCTAssertNil(five)
        XCTAssertNil(four)
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls.map(\.path), ["Work"])
    }

    /// Offline with nothing saved: the body entry stays rather than being
    /// removed under a guessed key, and nothing throws.
    func testWhenNoValidityResolvesTheBodyIsLeftAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await makeClient(imap)
        try await client.bodyCache.store(folder: "Work", uidValidity: 0, uid: 5, bytes: bytes)

        await client.forgetRemovedMessages([MessageRef(folder: "Work", uid: 5)])

        let left = await body(client, folder: "Work", uidValidity: 0, uid: 5)
        XCTAssertEqual(left, bytes, "nothing is removed under 0")
    }

    /// A ref minted before the folder's UIDVALIDITY changed: its UID may name
    /// another message in the snapshot now, so that row stays. Its body, under
    /// its own old validity, goes.
    func testARefFromAReplacedUIDSpaceLeavesTheSnapshotsRowAlone() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)
        try await seedSnapshot(client, folder: "Work", uidValidity: 8, uids: [5, 4])
        try await client.bodyCache.store(folder: "Work", uidValidity: 7, uid: 5, bytes: bytes)
        try await client.bodyCache.store(folder: "Work", uidValidity: 8, uid: 5, bytes: bytes)

        await client.forgetRemovedMessages([MessageRef(folder: "Work", uid: 5, uidValidity: 7)])

        let rows = await cachedUIDs(client, folder: "Work")
        XCTAssertEqual(rows, [5, 4])
        let old = await body(client, folder: "Work", uidValidity: 7, uid: 5)
        let current = await body(client, folder: "Work", uidValidity: 8, uid: 5)
        XCTAssertNil(old)
        XCTAssertEqual(current, bytes)
    }

    func testNoRefsMakesNoCall() async throws {
        let imap = FakeImapClient()
        let client = try await makeClient(imap)

        await client.forgetRemovedMessages([])

        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty)
    }
}
