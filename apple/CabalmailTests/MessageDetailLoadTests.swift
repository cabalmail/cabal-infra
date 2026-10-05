import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: pins what opening a message in
/// the reader does today, before the mail store layer absorbs
/// `MessageDetailViewModel.load()` and its body cache. `load()` had no tests
/// at all until `FakeImapClient.fetchBody` became scriptable.
///
/// Protects: the API-backed body fetch the reader runs on since #371; the body
/// cache key (folder, UIDVALIDITY, uid) and the STATUS fallback the reader
/// takes when the folder has no envelope snapshot, including what that
/// fallback does offline; the threading identity the reply path overlays
/// (Phase 0 of docs/draft-sync-and-threading.md); and the attachment strip /
/// inline `cid:` images. The failure surface lives in
/// `MessageDetailLoadFailureTests`, mark-as-read on open in
/// `MessageDetailMarkSeenTests`, and which parts are the body and where
/// attachment files go in `MessageDetailAttachmentTests`.
@MainActor
final class MessageDetailLoadTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!
    private let uid: UInt32 = 7

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// A reader on INBOX/`uid` whose folder has an envelope snapshot, so the
    /// open never needs STATUS.
    private func snapshottedReader(imap: FakeImapClient, uid: UInt32? = nil) async throws -> MessageDetailViewModel {
        let model = try await fixture.makeReader(imap: imap, uid: uid ?? self.uid)
        try await fixture.seedSnapshot(model)
        return model
    }

    // MARK: - Network path

    func testANetworkOpenRendersBothAlternativesAndCachesTheBytesUnderTheSnapshotValidity() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await snapshottedReader(imap: imap)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertEqual(model.htmlBody, MessageDetailMimeFixture.alternativeHTML)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertTrue(model.inlineImages.isEmpty)
        let fetches = await MessageDetailLoadFixture.fetchKeys(imap)
        XCTAssertEqual(fetches, ["INBOX#7"])
        let statusCalls = await imap.statusCalls
        XCTAssertTrue(statusCalls.isEmpty, "the snapshot's UIDVALIDITY is used; STATUS is not asked")
        let cached = await fixture.cachedBody(for: model)
        XCTAssertEqual(cached, MessageDetailMimeFixture.alternative, "keyed (INBOX, 42, 7)")
        let underZero = await fixture.cachedBody(for: model, uidValidity: 0)
        XCTAssertNil(underZero, "and under no other UIDVALIDITY")
    }

    func testANetworkOpenParsesTheThreadingIdsAndOverlaysThemOnTheEnvelope() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await snapshottedReader(imap: imap)
        XCTAssertNil(model.envelope.messageId, "the list envelope carries no threading identity")

        await model.load()

        XCTAssertEqual(model.threadingMessageId, "<reply-1@example.com>")
        XCTAssertEqual(model.threadingInReplyTo, "<root-1@example.com>")
        XCTAssertEqual(model.threadingReferences, ["<root-0@example.com>", "<root-1@example.com>"])
        XCTAssertEqual(model.threadedEnvelope.messageId, "<reply-1@example.com>")
        XCTAssertEqual(model.threadedEnvelope.inReplyTo, "<root-1@example.com>")
        XCTAssertEqual(model.threadedEnvelope.references, ["<root-0@example.com>", "<root-1@example.com>"])
        XCTAssertEqual(model.threadedEnvelope.uid, uid)
        let subject = model.rootHeaders.first { $0.name == "Subject" }?.value
        XCTAssertEqual(subject, "Characterization", "root headers are kept for the Drafts resume path")
    }

    // MARK: - Body cache

    func testACachedBodyRendersWithoutAFetch() async throws {
        // Unscripted, `fetchBody` throws, so an accidental fetch shows up as
        // an error instead of a body.
        let imap = FakeImapClient()
        let model = try await snapshottedReader(imap: imap)
        try await fixture.cacheBody(MessageDetailMimeFixture.alternative, for: model)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertEqual(model.htmlBody, MessageDetailMimeFixture.alternativeHTML)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasAttemptedLoad)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    func testABodyCachedUnderAnotherValidityOrFolderIsNotServed() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await snapshottedReader(imap: imap)
        let stale = Data("Subject: stale\r\n\r\nstale".utf8)
        try await model.client.bodyCache.store(folder: "INBOX", uidValidity: 41, uid: uid, bytes: stale)
        try await model.client.bodyCache.store(folder: "Archive", uidValidity: 42, uid: uid, bytes: stale)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        let fetches = await MessageDetailLoadFixture.fetchKeys(imap)
        XCTAssertEqual(fetches, ["INBOX#7"])
    }

    func testWithoutASnapshotStatusSuppliesTheValidityThatKeysTheCache() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(uidValidity: 9))])
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.cacheBody(MessageDetailMimeFixture.alternative, for: model, uidValidity: 9)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        let statusCalls = await imap.statusCalls
        XCTAssertEqual(statusCalls.map(\.path), ["INBOX"])
        XCTAssertEqual(statusCalls.map(\.flagged), [false], "the cheap STATUS, without the flagged count")
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    func testWithoutASnapshotAStatusWithNoValidityKeysTheCacheAtZero() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.success(FolderStatus(messages: 3))])
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await fixture.makeReader(imap: imap, uid: uid)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        let cached = await fixture.cachedBody(for: model, uidValidity: 0)
        XCTAssertEqual(cached, MessageDetailMimeFixture.alternative)
    }

    /// Offline, with no envelope snapshot for the folder (a search hit's
    /// source folder, or one Mark All Read has just invalidated), a body
    /// already on disk still opens: the reader looks it up under the
    /// UIDVALIDITY the folder last reported (#1810). Before, the failed STATUS
    /// ended the open without a look in the cache.
    func testOfflineACachedBodyOpensUnderTheFoldersSavedValidity() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let client = try await fixture.makeClientSavingFolderState(imap: imap)
        await fixture.saveFolderStatus(client)
        let model = try await fixture.makeReader(imap: imap, uid: uid, client: client)
        try await fixture.cacheBody(MessageDetailMimeFixture.alternative, for: model)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertNil(model.errorMessage)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    /// The saved UIDVALIDITY is a cache key only: with nothing saved for the
    /// folder, a failed STATUS still ends the open (#1810).
    func testOfflineWithNothingSavedForTheFolderTheStatusErrorStands() async throws {
        let imap = FakeImapClient()
        await imap.scriptStatusResults([.failure(CabalmailError.network("offline"))])
        let model = try await fixture.makeReader(imap: imap, uid: uid)
        try await fixture.cacheBody(MessageDetailMimeFixture.alternative, for: model)

        await model.load()

        XCTAssertNil(model.plainText)
        XCTAssertNil(model.htmlBody)
        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. offline.")
        XCTAssertTrue(model.hasAttemptedLoad)
        let fetches = await imap.fetchBodyCalls
        XCTAssertTrue(fetches.isEmpty)
    }

    /// The bytes arrived, so a failed write to the on-disk body cache no
    /// longer fails the open (#1811).
    func testAFailedCacheWriteStillOpensTheMessage() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.alternative)])
        let model = try await snapshottedReader(imap: imap)
        // A plain file where the cache's root directory should be: every
        // store under it fails, and the cleanup still removes it.
        let cacheRoot = await model.client.bodyCache.directory
        try FileManager.default.removeItem(at: cacheRoot)
        try Data().write(to: cacheRoot)

        await model.load()

        XCTAssertEqual(model.plainText, MessageDetailMimeFixture.alternativePlain)
        XCTAssertEqual(model.htmlBody, MessageDetailMimeFixture.alternativeHTML)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasAttemptedLoad)
        let fetches = await MessageDetailLoadFixture.fetchKeys(imap)
        XCTAssertEqual(fetches, ["INBOX#7"])
    }

    func testAnEmptyBodyRendersAsEmptyPlainTextAndIsCached() async throws {
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(Data())])
        let model = try await snapshottedReader(imap: imap)

        await model.load()

        XCTAssertEqual(model.plainText, "", "no Content-Type means text/plain")
        XCTAssertNil(model.htmlBody)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasAttemptedLoad)
        let cached = await fixture.cachedBody(for: model)
        XCTAssertEqual(cached, Data())

        // The cached empty body is what the next open gets, without a fetch.
        let reopened = try await fixture.makeReader(imap: imap, uid: uid, client: model.client)
        await reopened.load()
        XCTAssertEqual(reopened.plainText, "")
        let fetches = await imap.fetchBodyCalls
        XCTAssertEqual(fetches.count, 1)
    }

    // MARK: - Attachments and inline images

    func testAMixedMessageListsItsAttachmentsAndEmbedsItsCidImage() async throws {
        let uid: UInt32 = 4_294_960_011
        let imap = FakeImapClient()
        await imap.scriptBody(folder: "INBOX", uid: uid, [.success(MessageDetailMimeFixture.mixed)])
        let model = try await snapshottedReader(imap: imap, uid: uid)

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.plainText)
        XCTAssertEqual(model.htmlBody, #"<p>Logo: <img src="cid:logo@example.com"></p>"#)
        let logo = try XCTUnwrap(URL(string: "data:image/png;base64,iVBORw0KGgo="))
        XCTAssertEqual(model.inlineImages, ["logo@example.com": logo], "the cid image is embedded as data:, not listed")
        XCTAssertEqual(model.attachments.count, 2)
        guard model.attachments.count == 2 else { return }

        let report = model.attachments[0]
        XCTAssertEqual(report.id, "report.pdf", "no Content-ID, so the id is the file name")
        XCTAssertEqual(report.filename, "report.pdf")
        XCTAssertEqual(report.mimeType, "application/pdf")
        XCTAssertEqual(report.size, 9)
        XCTAssertEqual(try Data(contentsOf: report.fileURL), Data("%PDF-1.4\n".utf8))

        let unnamed = model.attachments[1]
        XCTAssertTrue(unnamed.filename.hasPrefix("attachment-"), unnamed.filename)
        XCTAssertTrue(unnamed.filename.hasSuffix(".bin"), unnamed.filename)
        XCTAssertEqual(unnamed.id, unnamed.filename)
        XCTAssertEqual(unnamed.mimeType, "application/octet-stream")
        XCTAssertEqual(unnamed.size, 4)
        XCTAssertEqual(try Data(contentsOf: unnamed.fileURL), Data([0, 1, 2, 3]))
    }
}
