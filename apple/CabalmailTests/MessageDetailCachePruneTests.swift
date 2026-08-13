import XCTest
import CabalmailKit
@testable import Cabalmail

// Pins the cache-eviction contract the reader's dispose / move / purge
// paths share: once the server confirms the message has left the folder,
// both the cached envelope row and the cached body go; if the server call
// fails, the persistent snapshot is left alone (pruning early would leave
// it disagreeing with the server on a transient failure).
@MainActor
final class MessageDetailCachePruneTests: XCTestCase {

    private let uid: UInt32 = 7
    private let uidValidity: UInt32 = 42

    private func makeModel(
        imap: FakeImapClient,
        folderPath: String = "INBOX"
    ) throws -> MessageDetailViewModel {
        MessageDetailViewModel(
            folder: Folder(path: folderPath, attributes: [], isSubscribed: true),
            envelope: TestFixtures.makeEnvelope(uid: uid),
            client: try TestFixtures.makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
    }

    /// Seeds both caches with the open message so a prune is observable.
    /// The envelope snapshot also supplies the UIDVALIDITY, which is what
    /// keys the body cache.
    private func seedCaches(_ model: MessageDetailViewModel) async throws {
        try await model.client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: uidValidity,
                uidNext: uid + 1,
                envelopes: [uid: TestFixtures.makeEnvelope(uid: uid)]
            ),
            for: model.folder.path
        )
        try await model.client.bodyCache.store(
            folder: model.folder.path,
            uidValidity: uidValidity,
            uid: uid,
            bytes: Data("raw message".utf8)
        )
    }

    private func cachedEnvelope(_ model: MessageDetailViewModel) async -> Envelope? {
        await model.client.envelopeCache.snapshot(for: model.folder.path)?.envelopes[uid]
    }

    private func cachedBody(_ model: MessageDetailViewModel) async -> Data? {
        await model.client.bodyCache.fetch(
            folder: model.folder.path,
            uidValidity: uidValidity,
            uid: uid
        )
    }

    func testDisposeDropsTheEnvelopeRowAndTheCachedBody() async throws {
        let model = try makeModel(imap: FakeImapClient())
        try await seedCaches(model)

        await model.dispose()

        let envelope = await cachedEnvelope(model)
        let body = await cachedBody(model)
        XCTAssertNil(envelope, "a confirmed dispose must drop the cached envelope row")
        XCTAssertNil(body, "a confirmed dispose must drop the cached body")
    }

    func testMoveDropsTheEnvelopeRowAndTheCachedBody() async throws {
        let model = try makeModel(imap: FakeImapClient())
        try await seedCaches(model)

        await model.move(to: "Projects")

        let envelope = await cachedEnvelope(model)
        let body = await cachedBody(model)
        XCTAssertNil(envelope, "a confirmed move must drop the cached envelope row")
        XCTAssertNil(body, "a confirmed move must drop the cached body")
    }

    func testPurgeDropsTheEnvelopeRowAndTheCachedBody() async throws {
        let model = try makeModel(imap: FakeImapClient(), folderPath: FolderTree.trashPath)
        try await seedCaches(model)

        await model.purge()

        let envelope = await cachedEnvelope(model)
        let body = await cachedBody(model)
        XCTAssertNil(envelope, "a confirmed purge must drop the cached envelope row")
        XCTAssertNil(body, "a confirmed purge must drop the cached body")
    }

    func testFailedDisposeLeavesBothCachesIntact() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.transport("no route"))])
        let model = try makeModel(imap: imap)
        try await seedCaches(model)

        await model.dispose()

        let envelope = await cachedEnvelope(model)
        let body = await cachedBody(model)
        XCTAssertNotNil(envelope, "a failed dispose must leave the cached envelope row alone")
        XCTAssertNotNil(body, "a failed dispose must leave the cached body alone")
    }

    func testFailedPurgeLeavesBothCachesIntact() async throws {
        let imap = FakeImapClient()
        await imap.scriptPurgeResults([.failure(CabalmailError.transport("no route"))])
        let model = try makeModel(imap: imap, folderPath: FolderTree.trashPath)
        try await seedCaches(model)

        await model.purge()

        let envelope = await cachedEnvelope(model)
        let body = await cachedBody(model)
        XCTAssertNotNil(envelope, "a failed purge must leave the cached envelope row alone")
        XCTAssertNotNil(body, "a failed purge must leave the cached body alone")
    }
}
