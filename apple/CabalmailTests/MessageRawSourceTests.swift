import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: the raw RFC 5322 bytes behind
/// View Source (`MessageDetailViewModel.rawSourceBytes()`) and the list's
/// drag-out (`MessageRawSource.bytes`), both served through the reader's
/// body cache.
///
/// `MessageRawSource.bytes` repeats the reader's cache-then-fetch steps
/// (`MessageDetailViewModel.fetchBodyBytes`) for a caller with no reader, so
/// it shares the reader's quirks: the UIDVALIDITY comes from the folder's
/// envelope snapshot or else a cheap STATUS, a STATUS failure ends it before
/// the cache is consulted, and a failed cache write fails it after the bytes
/// arrived. The planned mail store should absorb both copies; these tests
/// pin the drag-out copy so a merge that fixes only one shows up. The
/// reader's copy is pinned in `MessageDetailLoadTests`.
@MainActor
final class MessageRawSourceTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!
    private let uid: UInt32 = 7

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - The reader

    func testTheReadersRawSourceIsServedFromTheBodyCacheTheOpenFilled() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.seedSnapshot(model)
        await model.load()

        let source = try await model.rawSourceBytes()

        XCTAssertEqual(source, MessageDetailMimeFixture.alternative)
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1, "View Source after an open makes no second fetch")
    }

    // MARK: - MessageRawSource.bytes

    func testMessageRawSourceServesACachedBodyWithoutAFetch() async throws {
        let imap = FakeImapClient()
        let client = try await fixture.makeClient(imap: imap)
        let envelope = TestFixtures.makeEnvelope(uid: uid)
        try await fixture.seedSnapshot(client: client, folder: "INBOX", envelopes: [envelope])
        let bytes = Data("Subject: cached\r\n\r\ncached".utf8)
        try await client.bodyCache.store(folder: "INBOX", uidValidity: fixture.uidValidity, uid: uid, bytes: bytes)

        let source = try await MessageRawSource.bytes(client: client, folder: "INBOX", uid: uid)

        XCTAssertEqual(source, bytes)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty)
    }

    func testMessageRawSourceFetchesAndCachesAMiss() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let client = try await fixture.makeClient(imap: imap)
        let envelope = TestFixtures.makeEnvelope(uid: uid)
        try await fixture.seedSnapshot(client: client, folder: "INBOX", envelopes: [envelope])

        let source = try await MessageRawSource.bytes(client: client, folder: "INBOX", uid: uid)

        XCTAssertEqual(source, MessageDetailMimeFixture.alternative)
        let fetches = await MessageDetailLoadFixture.fetchKeys(imap)
        XCTAssertEqual(fetches, ["INBOX#7"])
        let cached = await client.bodyCache.fetch(folder: "INBOX", uidValidity: fixture.uidValidity, uid: uid)
        XCTAssertEqual(cached, MessageDetailMimeFixture.alternative)
    }

    func testMessageRawSourceWithoutASnapshotKeysTheCacheByStatus() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(uidValidity: 9))])
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let client = try await fixture.makeClient(imap: imap)

        _ = try await MessageRawSource.bytes(client: client, folder: "INBOX", uid: uid)

        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls.map(\.flagged), [false])
        let cached = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 9, uid: uid)
        XCTAssertEqual(cached, MessageDetailMimeFixture.alternative)
    }

    /// The reader's offline lookup applies to a drag-out too: with no
    /// snapshot and STATUS out of reach, a cached body is found under the
    /// folder's saved UIDVALIDITY (#1810; see `MessageDetailLoadTests`
    /// `testOfflineACachedBodyOpensUnderTheFoldersSavedValidity`).
    func testMessageRawSourceOfflineFindsACachedBodyUnderTheSavedValidity() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await fixture.makeClientSavingFolderState(imap: imap)
        await fixture.saveFolderStatus(client)
        let bytes = Data("Subject: cached\r\n\r\ncached".utf8)
        try await client.bodyCache.store(folder: "INBOX", uidValidity: fixture.uidValidity, uid: uid, bytes: bytes)

        let dragged = try await MessageRawSource.bytes(client: client, folder: "INBOX", uid: uid)

        XCTAssertEqual(dragged, bytes)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    /// The reader's twin (`MessageDetailLoadTests.testAFailedCacheWriteStillOpensTheMessage`):
    /// the bytes arrived, so a failed body-cache write no longer fails the
    /// drag-out (#1811).
    func testMessageRawSourceReturnsTheBytesWhenTheCacheWriteFails() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let client = try await fixture.makeClient(imap: imap)
        try await fixture.seedSnapshot(
            client: client,
            folder: "INBOX",
            envelopes: [TestFixtures.makeEnvelope(uid: uid)]
        )
        // A plain file where the cache's root directory should be: every
        // store under it fails, and the cleanup still removes it.
        let cacheRoot = await client.bodyCache.directory
        try FileManager.default.removeItem(at: cacheRoot)
        try Data().write(to: cacheRoot)

        let dragged = try await MessageRawSource.bytes(client: client, folder: "INBOX", uid: uid)

        XCTAssertEqual(dragged, MessageDetailMimeFixture.alternative)
        let fetches = await MessageDetailLoadFixture.fetchKeys(imap)
        XCTAssertEqual(fetches, ["INBOX#7"], "fetched once; the bytes were in hand")
    }
}
